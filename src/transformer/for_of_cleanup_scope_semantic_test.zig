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
    for ([_]u2{ 0, 1, 2, 3 }) |mode| {
        const state_machine = mode & 1 != 0;
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
            if (node.tag == .for_of_statement) {
                source_loop = @fromBackingInt(@intCast(raw));
                break;
            }
        }
        try std.testing.expect(!source_loop.isNone());
        const source_scope = t.outputOwnedScope(source_loop).?;
        const parent_scope = t.outputScopeParent(source_scope);
        const variable_owner = t.nearestVarScope(source_scope);
        var input = source_loop;
        if (mode & 2 != 0) {
            input = try t.ast.addNode(t.ast.getNode(source_loop));
            try t.remapCopiedScopeOwner(source_loop, input);
        }
        t.current_scope = parent_scope;
        if (state_machine) {
            t.state_machine_depth = 1;
            t.generator_operation_scope = parent_scope;
            t.generator_state_machine_scope = t.nearestVarScope(source_scope);
        }
        const output = try ForOf.rewriteForOf(&t, input, t.ast.getNode(input), .none, state_machine);
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
            } else if (raw >= t.parser_node_count and (node.tag == .block_statement or node.tag == .catch_clause)) return error.MissingGeneratedWrapperScope;
            if (node.tag == .import_expression) {
                const provenance = t.semantic_editor.?.node_scope_provenance.get(work.node) orelse return error.MissingMovedImportProvenance;
                try std.testing.expectEqual(scope, provenance.scope);
                try std.testing.expectEqual(analyzer.node_scope_provenance.get(work.node).?.source_node, provenance.source_node);
            }
            if (raw < t.parser_node_count and actual_ref_nodes.contains(raw) and t.getSymbolIdAt(work.node) != null) {
                const reference = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingPreservedSourceReference;
                try std.testing.expectEqual(t.getSymbolIdAt(work.node).?, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(scope, reference.scope_id);
            }
            if (raw >= t.parser_node_count) {
                if (node.tag == .block_statement or node.tag == .catch_clause) {
                    const expected: @import("../semantic/scope.zig").ScopeKind = if (node.tag == .catch_clause) .catch_clause else .block;
                    try std.testing.expectEqual(expected, t.semantic_editor.?.scopes.items[scope.toIndex()].kind);
                    generated_scopes += 1;
                }
                if (node.tag == .for_statement) try std.testing.expectEqual(source_scope, scope);
                if (node.tag == .binding_identifier) {
                    const sid = t.getSymbolIdAt(work.node) orelse return error.MissingCreationBinding;
                    const symbol = t.semantic_editor.?.symbols.items[sid];
                    if (symbol.kind == .catch_binding) {
                        try std.testing.expectEqual(scope, symbol.scope_id);
                        try std.testing.expect(symbol.decl_flags.is_catch_binding);
                    } else {
                        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
                        try std.testing.expectEqual(variable_owner, symbol.scope_id);
                    }
                }
                if (actual_ref_nodes.contains(raw)) {
                    const sid = t.getSymbolIdAt(work.node) orelse return error.MissingCreationSymbolId;
                    const ref = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingCreationReference;
                    try std.testing.expectEqual(sid, @backingInt(ref.symbol_id));
                    try std.testing.expectEqual(scope, ref.scope_id);
                    const is_write = !work.parent.isNone() and t.ast.getNode(work.parent).tag == .assignment_expression and t.ast.getNode(work.parent).data.binary.left == work.node;
                    try std.testing.expectEqual(is_write, ref.flags.write);
                    try std.testing.expectEqual(!is_write, ref.flags.read);
                    generated_refs += 1;
                }
            }
            var children = walk.children(t.ast, node);
            while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope, .parent = work.node });
        }
        try std.testing.expect(generated_scopes >= 8);
        try std.testing.expect(generated_refs >= 13);
    }
}

test "for of cleanup source 1 before output visitation" {
    try check("async function run(source){for(const value of source){use(value);}}");
}

test "for of cleanup source 2 before output visitation" {
    try check("async function run(source){for(const value of source){if(value)break;}}");
}

test "for of cleanup source 3 before output visitation" {
    try check("async function run(source){for(const value of source){return value;}}");
}

test "for of cleanup source 4 before output visitation" {
    try check("async function run(source){for(const value of source){throw value;}}");
}

test "for of cleanup source 5 before output visitation" {
    try check("async function run(source){try{for(const value of source.map(item=>item)){use(value);}}catch(error){use(error);}}");
}

test "for of cleanup source 6 before output visitation" {
    try check("async function run(source){for(const {value} of source){use(()=>value);}}");
}

test "for of cleanup source 7 before output visitation" {
    try check("async function run(source){for(const [value=42] of source){await use(value);}}");
}

test "for of cleanup source 8 before output visitation" {
    try check("async function run(source){outer:for(const value of source){if(value)continue outer;break outer;}}");
}

test "for of cleanup source 9 before output visitation" {
    try check("async function run(source){const _err=1,_step=2;for(const value of source){{const value=3;use(value,_err,_step);}}}");
}

test "for of cleanup source 10 before output visitation" {
    try check("async function* run(source){try{for(const value of source){yield value;}}finally{use(42);}}");
}

test "for of cleanup source 11 import provenance before output visitation" {
    try check("async function run(source){for(const value of (await import(source)).values){use(value);}}");
}
