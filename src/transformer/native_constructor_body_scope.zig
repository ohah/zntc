//! Prepare the real lexical body boundary of a guarded native constructor.
//! The caller must materialize function-declaration cells before moving their
//! statements into the try body; this module does not change their FDI policy.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const edit = @import("transformer/semantic_edit.zig");

fn moveBinding(self: anytype, binding: ast.NodeIndex, source: ScopeId, target: ScopeId) !void {
    if (binding.isNone()) return;
    const id = self.getSymbolIdAt(binding) orelse @panic("constructor lexical binding has no source identity");
    const editor = &self.semantic_editor.?;
    if (editor.symbols.items[id].scope_id != source) return;
    editor.relocateSymbol(@fromBackingInt(@intCast(id)), target) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("constructor lexical storage handoff failed: {s}", .{@errorName(err)}),
    };
}

/// Keep the native function, its formals, native arguments and actual var
/// storage in their existing ScopeId. Only bindings physically owned by the
/// new try block move. The original body is its actual owner before visiting.
pub fn prepare(self: anytype, body: ast.NodeIndex, constructor_scope: ScopeId) !ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    if (body.isNone() or self.ast.getNode(body).tag != .block_statement)
        @panic("constructor body scope requires its actual block");
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (constructor_scope.isNone() or constructor_scope.toIndex() >= scopes.len or scopes[constructor_scope.toIndex()].kind != .function)
        @panic("constructor body scope has no actual function owner");
    if (self.outputOwnedScope(body)) |existing| {
        if (existing != constructor_scope) @panic("constructor body already has a distinct scope owner");
    }
    const scope = try self.addGeneratedScope(constructor_scope, body, .block);
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    var bindings: std.ArrayList(ast.NodeIndex) = .empty;
    defer bindings.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .function_declaration,
            .function_expression,
            .function,
            .arrow_function_expression,
            .method_definition,
            .static_block,
            => continue,
            .class_declaration => {
                try moveBinding(self, self.ast.readExtraNode(node.data.extra, ast.ClassExtra.name), constructor_scope, scope);
                continue;
            },
            .class_expression => continue,
            .variable_declaration => {
                bindings.clearRetainingCapacity();
                try @import("es2015_block_scoping.zig").ES2015BlockScoping(@TypeOf(self.*)).collectLexicalVarBindings(self, idx, &bindings);
                for (bindings.items) |binding| try moveBinding(self, binding, constructor_scope, scope);
            },
            else => {},
        }
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    try @import("class_strict_context.zig").moveSourceReferences(self, body, constructor_scope, constructor_scope, scope);
    try edit.reparentGeneratedBodyScopes(self, constructor_scope, scope, body);
    return scope;
}

test "native constructor body scope preserves function storage and moves lexical bindings before walking" {
    const source = "class P{};class D extends P{value=7;constructor(p){var keep=arguments;let [x]=p;const read=function(){return x};class Local{};using resource=p;{let nested=x;keep=nested}return read}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    const Transformer = @import("transformer.zig").Transformer;
    var t = try Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    var constructor: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, index| if (node.tag == .method_definition) {
        constructor = @fromBackingInt(@as(u32, @intCast(index)));
        break;
    };
    try std.testing.expect(!constructor.isNone());
    const function_scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(constructor)).?);
    const body = parser.ast.readExtraNode(parser.ast.getNode(constructor).data.extra, ast.MethodExtra.body);
    const source_symbols = try a.dupe(@import("../semantic/symbol.zig").Symbol, analyzer.symbols.items);
    const source_scopes = try a.dupe(@import("../semantic/scope.zig").Scope, analyzer.scopes.items);
    const body_scope = try prepare(&t, body, function_scope);
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(function_scope, t.outputOwnedScope(constructor).?);
    try std.testing.expectEqual(body_scope, t.outputOwnedScope(body).?);
    try std.testing.expectEqual(function_scope, editor.scopes.items[body_scope.toIndex()].parent);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, editor.scopes.items[function_scope.toIndex()].kind);
    var moved: usize = 0;
    var native_arguments: usize = 0;
    for (source_symbols, 0..) |symbol, id| {
        const current = editor.symbols.items[id];
        if (current.scope_id != symbol.scope_id) {
            try std.testing.expectEqual(function_scope, symbol.scope_id);
            try std.testing.expectEqual(body_scope, current.scope_id);
            try std.testing.expectEqual(symbol.name, current.name);
            try std.testing.expectEqual(symbol.declaration_span, current.declaration_span);
            moved += 1;
        }
        if (symbol.synthetic_kind == .implicit_arguments and symbol.scope_id == function_scope) {
            try std.testing.expectEqual(function_scope, current.scope_id);
            native_arguments += 1;
        }
    }
    // x, read, Local, resource; the nested block owns its own `nested`.
    try std.testing.expectEqual(@as(usize, 4), moved);
    try std.testing.expectEqual(@as(usize, 1), native_arguments);
    for (source_scopes, 0..) |scope, id| {
        if (scope.parent == function_scope)
            try std.testing.expectEqual(body_scope, editor.scopes.items[id].parent);
    }
    for (analyzer.references.items, editor.references.items) |previous, current| {
        try std.testing.expectEqual(previous.symbol_id, current.symbol_id);
        try std.testing.expectEqual(previous.node_index, current.node_index);
        try std.testing.expectEqual(previous.declaration_node_index, current.declaration_node_index);
        if (!previous.flags.declare and previous.scope_id == function_scope)
            try std.testing.expectEqual(body_scope, current.scope_id);
    }
    const finalizer = try t.ast.addNode(.{ .tag = .block_statement, .span = t.ast.getNode(body).span, .data = .{ .list = try t.ast.addNodeList(&.{}) } });
    _ = try t.addGeneratedScope(function_scope, finalizer, .block);
    const attempt = try t.ast.addNode(.{ .tag = .try_statement, .span = t.ast.getNode(body).span, .data = .{ .ternary = .{ .a = body, .b = .none, .c = finalizer } } });
    const outer_body = try t.ast.addNode(.{ .tag = .block_statement, .span = t.ast.getNode(body).span, .data = .{ .list = try t.ast.addNodeList(&.{attempt}) } });
    t.ast.extra_data.items[t.ast.getNode(constructor).data.extra + ast.MethodExtra.body] = @backingInt(outer_body);
    const utils = @import("output_scope_test_utils.zig");
    var parents = try utils.buildParentMap(a, t.ast, root);
    defer parents.deinit(a);
    for (editor.references.items) |reference| {
        if (reference.flags.declare or reference.node_index.isNone()) continue;
        const actual_scope = utils.expectedScope(t.ast, root, &parents, &editor.scope_owner_map, @backingInt(reference.node_index)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(actual_scope, reference.scope_id);
        const coordinates = utils.expectedStatementCoordinates(t.ast, &parents, @backingInt(reference.node_index)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(coordinates.stmt_idx, reference.stmt_idx);
        try std.testing.expectEqual(coordinates.scope_stmt_idx, reference.scope_stmt_idx);
    }
}
