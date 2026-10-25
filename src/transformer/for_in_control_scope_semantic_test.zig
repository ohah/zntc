const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ForOf = @import("es2015_for_of.zig").ES2015ForOf(Transformer);

fn check(source: []const u8) !void {
    for ([_]bool{ false, true }) |copied_source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        var t = try Transformer.init(a, &parser.ast, .{});
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        t.semantic_edit_enabled = true;
        var source_loop: ast.NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .for_in_statement) {
                source_loop = @fromBackingInt(@intCast(raw));
                break;
            }
        }
        try std.testing.expect(!source_loop.isNone());
        const source_scope = t.outputOwnedScope(source_loop).?;
        const parent_scope = t.outputScopeParent(source_scope);
        const variable_owner = t.nearestVarScope(source_scope);
        // A copied loop and a stale traversal cursor must still select the
        // producer's original ScopeId, never the enclosing scope by spelling.
        var input = source_loop;
        if (copied_source) {
            input = try t.ast.addNode(t.ast.getNode(source_loop));
            try t.remapCopiedScopeOwner(source_loop, input);
        }
        t.current_scope = parent_scope;
        t.state_machine_depth = 1;
        t.generator_operation_scope = parent_scope;
        t.generator_state_machine_scope = variable_owner;
        const switch_owner = try t.ast.addNode(.{ .tag = .switch_statement, .span = t.ast.getNode(source_loop).span, .data = .{ .extra = try t.ast.addExtras(&.{@backingInt(ast.NodeIndex.none),0,0}) } });
        t.generator_native_var_scope = try t.addGeneratedScope(variable_owner, switch_owner, .switch_block);
        const output = try ForOf.rewriteForIn(&t, input, t.ast.getNode(input));
        const wrapper_node = t.ast.getNode(output);
        const declaration = t.ast.getNode(@fromBackingInt(t.ast.extra_data.items[wrapper_node.data.list.start]));
        const declarations = t.ast.readExtra(declaration.data.extra, 1);
        var temp_ids: [4]u32 = undefined;
        for (0..3) |index| {
            const declarator = t.ast.getNode(t.ast.readExtraNode(declarations, @intCast(index)));
            temp_ids[index] = t.getSymbolIdAt(t.ast.readExtraNode(declarator.data.extra, 0)).?;
        }
        const main_loop = t.ast.getNode(@fromBackingInt(t.ast.extra_data.items[wrapper_node.data.list.start + 2]));
        const index_declaration = t.ast.getNode(t.ast.readExtraNode(main_loop.data.extra, 0));
        const index_declarator = t.ast.getNode(t.ast.readExtraNode(t.ast.readExtra(index_declaration.data.extra, 1), 0));
        temp_ids[3] = t.getSymbolIdAt(t.ast.readExtraNode(index_declarator.data.extra, 0)).?;
        var temp_uses: [4]usize = @splat(0);
        const actual_refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(a, t.ast, output);
        var actual_ref_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (actual_refs) |ref| try actual_ref_nodes.put(a, @backingInt(ref), {});
        const Work = struct { node: ast.NodeIndex, scope: ScopeId, parent: ast.NodeIndex = .none };
        var stack: std.ArrayList(Work) = .empty;
        try stack.append(a, .{ .node = output, .scope = parent_scope });
        var generated_refs: usize = 0;
        var generated_scopes: usize = 0;
        while (stack.pop()) |work| {
            if (work.node.isNone()) continue;
            const raw = @backingInt(work.node);
            const node = t.ast.getNode(work.node);
            var scope = work.scope;
            if (t.outputOwnedScope(work.node)) |owner| {
                scope = owner;
                if (scope != work.scope) try std.testing.expectEqual(work.scope, t.semantic_editor.?.scopes.items[scope.toIndex()].parent);
            } else if (raw >= t.parser_node_count and (node.tag == .block_statement or node.tag == .for_in_statement)) return error.MissingGeneratedWrapperScope;
            if (node.tag == .import_expression) {
                const provenance = t.semantic_editor.?.node_scope_provenance.get(work.node) orelse return error.MissingMovedImportProvenance;
                try std.testing.expectEqual(scope, provenance.scope);
                try std.testing.expectEqual(analyzer.node_scope_provenance.get(work.node).?.source_node, provenance.source_node);
            }
            if (raw < t.parser_node_count and actual_ref_nodes.contains(raw) and t.getSymbolIdAt(work.node) != null) {
                const reference = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingPreservedSourceReference;
                try std.testing.expectEqual(t.getSymbolIdAt(work.node).?, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(analyzer.symbol_ids.items[raw].?, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(scope, reference.scope_id);
            }
            if (raw >= t.parser_node_count) {
                if (node.tag == .block_statement or node.tag == .for_in_statement) {
                    const expected: @import("../semantic/scope.zig").ScopeKind = .block;
                    try std.testing.expectEqual(expected, t.semantic_editor.?.scopes.items[scope.toIndex()].kind);
                    generated_scopes += 1;
                }
                if (node.tag == .for_statement) try std.testing.expectEqual(source_scope, scope);
                if (node.tag == .for_in_statement) try std.testing.expect(scope != source_scope);
                if (node.tag == .binding_identifier) {
                    const sid = t.getSymbolIdAt(work.node) orelse return error.MissingCreationBinding;
                    const symbol = t.semantic_editor.?.symbols.items[sid];
                    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
                    try std.testing.expectEqual(variable_owner, symbol.scope_id);
                }
                if (actual_ref_nodes.contains(raw)) {
                    const sid = t.getSymbolIdAt(work.node) orelse return error.MissingCreationSymbolId;
                    const ref = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingCreationReference;
                    try std.testing.expectEqual(sid, @backingInt(ref.symbol_id));
                    try std.testing.expectEqual(scope, ref.scope_id);
                    const parent = t.ast.getNode(work.parent);
                    const updated = parent.tag == .update_expression;
                    const is_write = updated or (parent.tag == .assignment_expression and parent.data.binary.left == work.node) or (parent.tag == .for_in_statement and parent.data.ternary.a == work.node);
                    try std.testing.expectEqual(is_write, ref.flags.write);
                    try std.testing.expectEqual(!is_write or updated, ref.flags.read);
                    try std.testing.expectEqual(sid, t.exact_output_ref_symbol_ids.get(raw).?);
                    if (t.exact_output_ref_scope_ids.get(raw)) |planned| {
                        try std.testing.expectEqual(if (scope == source_scope) @backingInt(t.generator_native_var_scope) else @backingInt(scope), planned);
                    } else {
                        try std.testing.expectEqual(@backingInt(variable_owner), t.deferred_generator_for_in_body_ref_scopes.get(raw).?);
                    }
                    var matched: usize = 0;
                    for (temp_ids, 0..) |temp_id, index| {
                        if (temp_id == sid) {
                            temp_uses[index] += 1;
                            matched += 1;
                        }
                    }
                    try std.testing.expectEqual(@as(usize, 1), matched);
                    generated_refs += 1;
                }
            }
            var children = walk.children(t.ast, node);
            while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope, .parent = work.node });
        }
        try std.testing.expectEqual([4]usize{ 1, 3, 2, 3 }, temp_uses);
        for (temp_ids, temp_uses) |sid, count| try std.testing.expectEqual(count, t.semantic_editor.?.symbols.items[sid].reference_count);
        try std.testing.expect(generated_scopes >= 3);
        try std.testing.expect(generated_refs >= 9);
    }
}

test "for in control source 1 before output visitation" {
    try check("function* run(source){for(const key in source){use(key);yield key;}}");
}

test "for in control source 2 before output visitation" {
    try check("function* run(source){for(let key in source){const read=()=>key;use(read);yield key;}}");
}

test "for in control source 3 before output visitation" {
    try check("function* run(source){for(var key in source){yield key;}use(key);}");
}

test "for in control source 4 before output visitation" {
    try check("function* run(source){let key;for(key in source){yield key;}}");
}

test "for in control source 5 before output visitation" {
    try check("function* run(source){for(const key in source){const copy=key;use(()=>copy);yield copy;}}");
}

test "for in control source 6 before output visitation" {
    try check("function* run(source){for(const key in source)yield key;}");
}

test "for in control source 7 before output visitation" {
    try check("function* run(source){for(const key in source){const key=42;yield key;}}");
}

test "for in control source 8 before output visitation" {
    try check("function* run(source){for(const key in source){if(key)continue;yield key;}}");
}

test "for in control source 9 before output visitation" {
    try check("function* run(source){outer:for(const key in source){if(key)break outer;yield key;}}");
}

test "for in control source 10 before output visitation" {
    try check("function* run(source){for(const key in source.map(item=>item)){yield key;}}");
}

test "for in control source 11 before output visitation" {
    try check("async function* run(source){for(const key in (await import(source)).values){yield key;}}");
}
