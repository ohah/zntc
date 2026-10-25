//! Drive only source await suspensions; completing an iteration adds no await.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const helpers = @import("es_helpers.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Slot = struct { name: Span, id: SymbolId };
pub const Driver = struct { statements: []ast.NodeIndex, value: ast.NodeIndex };

fn block(self: anytype, statements: []const ast.NodeIndex, span: Span) !ast.NodeIndex {
    return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(statements) } });
}
fn slot(self: anytype, prefix: []const u8, scope: ScopeId, span: Span) !struct { value: Slot, binding: ast.NodeIndex } {
    var counter: u32 = 0;
    const name = try self.buildUniqueNameAvoidingDynamicEval(prefix, &counter, scope);
    const binding = try helpers.makeExactSyntheticBinding(self, name);
    const previous = self.current_scope;
    self.current_scope = scope;
    defer self.current_scope = previous;
    const id = (try self.declareSyntheticVar(binding, span)).?;
    return .{ .value = .{ .name = self.ast.getNode(binding).data.string_ref, .id = id }, .binding = binding };
}
fn ref(self: anytype, value: Slot, scope: ScopeId, span: Span, write: bool) !ast.NodeIndex {
    const node = try helpers.makeExactSyntheticRefFromSpan(self, value.name);
    try self.addSyntheticRefInScope(node, value.id, scope, .{ .read = !write, .write = write });
    _ = span;
    return node;
}
fn property(self: anytype, value: Slot, scope: ScopeId, name: []const u8, span: Span) !ast.NodeIndex {
    return helpers.makeStaticMember(self, try ref(self, value, scope, span, false), try helpers.makePropertyName(self, name), span);
}
fn invoke(self: anytype, iterator: Slot, scope: ScopeId, method: []const u8, args: []const ast.NodeIndex, span: Span) !ast.NodeIndex {
    return helpers.makeCallExpr(self, try property(self, iterator, scope, method, span), args, span);
}

/// Traverse only evaluation belonging to the enclosing source function.
/// Method keys/decorators execute outside the method; field initializers do not.
fn enqueueSourceChildren(self: anytype, stack: *std.ArrayList(ast.NodeIndex), idx: ast.NodeIndex) !void {
    const node = self.ast.getNode(idx);
    switch (node.tag) {
        .function_declaration, .function_expression, .function, .arrow_function_expression, .static_block => return,
        .method_definition => {
            var children = @import("../parser/ast_walk.zig").children(self.ast, node);
            while (children.next()) |child| {
                if (@import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(idx), @backingInt(child)))
                    try stack.append(self.allocator, child);
            }
            return;
        },
        .property_definition, .accessor_property => {
            try stack.append(self.allocator, self.ast.readExtraNode(node.data.extra, ast.PropertyExtra.key));
            const start = self.ast.readExtra(node.data.extra, ast.PropertyExtra.deco_start);
            const len = self.ast.readExtra(node.data.extra, ast.PropertyExtra.deco_len);
            for (0..len) |i| try stack.append(self.allocator, @fromBackingInt(self.ast.extra_data.items[start + i]));
            return;
        },
        else => {},
    }
    var children = @import("../parser/ast_walk.zig").children(self.ast, node);
    while (children.next()) |child| try stack.append(self.allocator, child);
}

pub fn hasSuspension(self: anytype, root: ast.NodeIndex, tag: ast.Node.Tag) !bool {
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);
        if (node.tag == tag) return true;
        if (tag == .await_expression and (node.tag == .for_await_of_statement or
            (node.tag == .variable_declaration and self.ast.variableDeclarationKind(node) == .await_using))) return true;
        try enqueueSourceChildren(self, &stack, idx);
    }
    return false;
}

/// Consume visited source awaits without entering another function's body.
pub fn awaitToYield(self: anytype, root: ast.NodeIndex) !void {
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        if (self.ast.getNode(idx).tag == .await_expression)
            self.ast.nodes.items[@backingInt(idx)].tag = .yield_expression;
        try enqueueSourceChildren(self, &stack, idx);
    }
}

pub fn build(self: anytype, call: ast.NodeIndex, scope: ScopeId, span: Span) !Driver {
    const iterator = try slot(self, "_awaitIterator", scope, span);
    const step = try slot(self, "_awaitStep", scope, span);
    const value = try slot(self, "_awaitValue", scope, span);
    const declarations = [_]ast.NodeIndex{
        try helpers.makeDeclarator(self, iterator.binding, call, span),
        try helpers.makeDeclarator(self, step.binding, try invoke(self, iterator.value, scope, "next", &.{}, span), span),
        try helpers.makeDeclarator(self, value.binding, .none, span),
    };
    const declaration = try helpers.makeVarDeclaration(self, &declarations, .@"var", span);
    const awaited = try helpers.makeAwaitExpression(self, try property(self, step.value, scope, "value", span), span);
    const assign_value = try helpers.makeAssignStmt(self, try ref(self, value.value, scope, span, true), awaited, span, 0);
    const try_body = try block(self, &.{assign_value}, span);
    const empty = try block(self, &.{}, span);
    const caught = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{ .left = .none, .right = empty, .flags = 0 } } });
    const catch_scope = try self.addGeneratedCatchScope(scope, caught);
    var error_counter: u32 = 0;
    const error_name = try self.buildUniqueNameAvoidingDynamicEval("_awaitError", &error_counter, catch_scope);
    const error_binding = try helpers.makeExactSyntheticBinding(self, error_name);
    const error_id = (try self.declareSyntheticInScope(error_binding, span, .catch_binding, catch_scope)).?;
    const error_ref = try helpers.makeExactSyntheticRef(self, error_name);
    try self.addSyntheticRefInScope(error_ref, error_id, catch_scope, .{ .read = true });
    const thrown = try invoke(self, iterator.value, catch_scope, "throw", &.{error_ref}, span);
    const assign_throw = try helpers.makeAssignStmt(self, try ref(self, step.value, catch_scope, span, true), thrown, span, 0);
    const again = try self.ast.addNode(.{ .tag = .continue_statement, .span = span, .data = .{ .unary = .{ .operand = .none, .flags = 0 } } });
    self.ast.nodes.items[@backingInt(caught)].data.binary.left = error_binding;
    self.ast.nodes.items[@backingInt(caught)].data.binary.right = try block(self, &.{ assign_throw, again }, span);
    const attempt = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{ .a = try_body, .b = caught, .c = .none } } });
    const next = try invoke(self, iterator.value, scope, "next", &.{try ref(self, value.value, scope, span, false)}, span);
    const assign_next = try helpers.makeAssignStmt(self, try ref(self, step.value, scope, span, true), next, span, 0);
    const test_done = try helpers.makeUnaryNot(self, try property(self, step.value, scope, "done", span), span);
    const loop_body = try block(self, &.{ attempt, assign_next }, span);
    const loop = try self.ast.addNode(.{ .tag = .while_statement, .span = span, .data = .{ .binary = .{ .left = test_done, .right = loop_body, .flags = 0 } } });
    return .{ .statements = try self.allocator.dupe(ast.NodeIndex, &.{ declaration, loop }), .value = try property(self, step.value, scope, "value", span) };
}
