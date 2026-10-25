const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ForOf = @import("es2015_for_of.zig").ES2015ForOf(Transformer);
const ForAwait = @import("es2018_for_await.zig").ES2018ForAwait(Transformer);

fn check(source: []const u8, is_async: bool, is_in: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    var original: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if ((if (is_in) node.tag == .for_in_statement else if (is_async) node.tag == .for_await_of_statement else node.tag == .for_of_statement)) original = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!original.isNone());
    const old = transformer.ast.getNode(original);
    const body = old.data.ternary.c;
    const loop_scope = transformer.outputOwnedScope(original).?;
    const old_body_scope = transformer.outputOwnedScope(body);
    transformer.current_scope = loop_scope;
    if (is_in) {
        transformer.state_machine_depth = 1;
        transformer.generator_operation_scope = loop_scope;
        transformer.generator_state_machine_scope = transformer.nearestVarScope(loop_scope);
    }
    const output = if (is_in)
        try ForOf.rewriteForIn(&transformer, original, old)
    else if (is_async)
        try ForAwait.rewriteForAwait(&transformer, original, old, .none, true, false)
    else
        try ForOf.rewriteForOf(&transformer, original, old, .none, false);
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    try stack.append(a, output);
    var new_body: ast.NodeIndex = .none;
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const node = transformer.ast.getNode(idx);
        if (node.tag == .block_statement and node.data.list.len == 2 and transformer.ast.extra_data.items[node.data.list.start + 1] == @backingInt(body)) {
            new_body = idx;
            break;
        }
        var children = walk.children(transformer.ast, node);
        while (children.next()) |child| try stack.append(a, child);
    }
    try std.testing.expect(!new_body.isNone());
    const new_scope = transformer.outputOwnedScope(new_body) orelse return error.MissingLoopBodyScope;
    const editor = &transformer.semantic_editor.?;
    var loop_owners: usize = 0;
    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        const emitted_body = switch (node.tag) {
            .for_statement => transformer.ast.readExtraNode(node.data.extra, 3),
            .while_statement => node.data.binary.right,
            else => continue,
        };
        if (emitted_body != new_body) continue;
        const actual_loop: ast.NodeIndex = @fromBackingInt(@intCast(raw));
        try std.testing.expectEqual(loop_scope, transformer.outputOwnedScope(actual_loop) orelse return error.MissingEmittedLoopOwner);
        loop_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), loop_owners);
    try std.testing.expectEqual(loop_scope, editor.scopes.items[new_scope.toIndex()].parent);
    if (old_body_scope) |scope| {
        try std.testing.expectEqual(scope, transformer.outputOwnedScope(body).?);
        try std.testing.expectEqual(new_scope, editor.scopes.items[scope.toIndex()].parent);
    }
    const Work = struct { node: ast.NodeIndex, scope: ScopeId };
    var refs: std.ArrayList(Work) = .empty;
    try refs.append(a, .{ .node = new_body, .scope = new_scope });
    var count: usize = 0;
    while (refs.pop()) |work| {
        if (work.node.isNone()) continue;
        const scope = transformer.outputOwnedScope(work.node) orelse work.scope;
        if (scope != work.scope)
            try std.testing.expectEqual(work.scope, editor.scopes.items[scope.toIndex()].parent);
        if (try editor.referenceForNode(work.node)) |reference| {
            if (!reference.flags.declare) {
                try std.testing.expectEqual(scope, reference.scope_id);
                count += 1;
            }
        }
        const node = transformer.ast.getNode(work.node);
        if (node.tag == .import_expression) {
            const provenance = editor.node_scope_provenance.get(work.node) orelse return error.MissingImportProvenance;
            try std.testing.expectEqual(scope, provenance.scope);
            const original_provenance = analyzer.node_scope_provenance.get(work.node).?;
            try std.testing.expectEqual(original_provenance.source_node, provenance.source_node);
        }
        if (node.tag == .binding_identifier) {
            if (transformer.getSymbolIdAt(work.node)) |sid| {
                const symbol = editor.symbols.items[sid];
                if (@backingInt(work.node) < analyzer.symbol_ids.items.len) {
                    if (analyzer.symbol_ids.items[@backingInt(work.node)]) |original_id|
                        try std.testing.expectEqual(original_id, sid);
                }
                if (symbol.kind == .variable_var and sid < analyzer.symbols.items.len)
                    try std.testing.expectEqual(analyzer.symbols.items[sid].scope_id, symbol.scope_id);
                if (symbol.kind == .variable_let or symbol.kind == .variable_const)
                    try std.testing.expectEqual(scope, symbol.scope_id);
            }
        }
        var children = walk.children(transformer.ast, node);
        while (children.next()) |child| try refs.append(a, .{ .node = child, .scope = scope });
    }
    try std.testing.expect(count > 0);
}

fn checkModes(source: []const u8) !void {
    try check(source, false, false);
    const in_source = try std.mem.replaceOwned(u8, std.testing.allocator, source, " of source", " in source");
    defer std.testing.allocator.free(in_source);
    try check(in_source, false, true);
    const async_source = try std.mem.replaceOwned(u8, std.testing.allocator, source, "function run", "async function run");
    defer std.testing.allocator.free(async_source);
    const await_source = try std.mem.replaceOwned(u8, std.testing.allocator, async_source, "for(", "for await(");
    defer std.testing.allocator.free(await_source);
    try check(await_source, true, false);
}

test "loop body lexical owner source 1 before visiting output" {
    try checkModes("function run(source){for(const value of source){use(value);}}");
}

test "loop body lexical owner source 2 before visiting output" {
    try checkModes("function run(source){for(let value of source){const read=()=>value;use(read);}}");
}

test "loop body lexical owner source 3 before visiting output" {
    try checkModes("function run(source){for(var value of source){use(value);}}");
}

test "loop body lexical owner source 4 before visiting output" {
    try checkModes("function run(source){let value;for(value of source){use(value);}}");
}

test "loop body lexical owner source 5 before visiting output" {
    try checkModes("function run(source){for(const {value} of source){use(value);}}");
}

test "loop body lexical owner source 6 before visiting output" {
    try checkModes("function run(source){for(const [value] of source){use(value);}}");
}

test "loop body lexical owner source 7 before visiting output" {
    try checkModes("function run(source){for(const [value,read=()=>value] of source){use(read);}}");
}

test "loop body lexical owner source 8 before visiting output" {
    try checkModes("function run(source){for(const [value=import('./dep.cjs')] of source){use(value);}}");
}

test "loop body lexical owner source 9 before visiting output" {
    try checkModes("function run(source){for(const value of source)use(value);}");
}

test "loop body lexical owner source 10 before visiting output" {
    try checkModes("function run(source){for(const value of source){let copy=value;{use(copy);}}}");
}

test "loop body lexical owner source 11 before visiting output" {
    try checkModes("function run(source){for(const value of source){import('./dep.cjs');use(value);}}");
}

test "loop body lexical owner source 12 before visiting output" {
    try checkModes("function run(source){for(const value of source){const read=()=>{import('./dep.cjs');return value;};use(read);}}");
}

test "loop body lexical owner source 13 direct head default before visiting output" {
    try checkModes("function run(source){const fallback=42;for(const [value=fallback] of source){use(value);}}");
}
test "loop body lexical owner source 14 captured body cell before visiting output" {
    try checkModes("function run(source){for(const value of source){const copy=value*2;use(()=>copy);}}");
}
