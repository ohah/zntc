//! Select the existing class producer for a native-class target that cannot
//! emit a constructor's lexical-super arrow. The target feature set is immutable.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub const Plan = struct {
    class_node: ast.NodeIndex,
    class_scope: ScopeId,
    constructor_node: ast.NodeIndex,
    constructor_scope: ScopeId,
    first_super_call: ast.NodeIndex,
    arrow_scope: ScopeId,
};

fn within(scopes: []const @import("../semantic/scope.zig").Scope, child: ScopeId, parent: ScopeId) bool {
    var current = child;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current.toIndex() >= scopes.len) return false;
        if (current == parent) return true;
        current = scopes[current.toIndex()].parent;
    }
    return false;
}

fn enclosingClass(scopes: []const @import("../semantic/scope.zig").Scope, child: ScopeId) ?ScopeId {
    var current = child;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current.toIndex() >= scopes.len) return null;
        if (scopes[current.toIndex()].kind == .class_body) return current;
        current = scopes[current.toIndex()].parent;
    }
    return null;
}

pub fn select(self: anytype, source: ast.NodeIndex, class: ast.Node) std.mem.Allocator.Error!?Plan {
    if (!self.semantic_edit_enabled or self.options.unsupported.class or !self.options.unsupported.arrow) return null;
    if (class.tag != .class_declaration and class.tag != .class_expression) return null;
    if (self.ast.readExtraNode(class.data.extra, ast.ClassExtra.super).isNone()) return null;
    const body = self.ast.getNode(self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body));
    if (body.tag != .class_body) return null;
    var constructor: ast.NodeIndex = .none;
    for (0..body.data.list.len) |offset| {
        const member = self.ast.readExtraNode(body.data.list.start, @intCast(offset));
        if (@import("es_helpers.zig").isClassConstructorMethod(self, member, self.ast.getNode(member))) {
            if (!constructor.isNone()) return null;
            constructor = member;
        }
    }
    if (constructor.isNone()) return null;
    const scope = self.outputOwnedScope(constructor) orelse return null;
    const class_scope = self.outputOwnedScope(source) orelse return null;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (scope.isNone() or scope.toIndex() >= scopes.len or scopes[scope.toIndex()].kind != .function or
        class_scope.isNone() or class_scope.toIndex() >= scopes.len or scopes[class_scope.toIndex()].kind != .class_body or class_scope == scope) return null;
    if (enclosingClass(scopes, scope) != class_scope) return null;
    const Work = struct { node: ast.NodeIndex, arrow_scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    const method = self.ast.getNode(constructor);
    const parameters = self.ast.readExtraNode(method.data.extra, ast.MethodExtra.params);
    const parameter_scope = self.outputOwnedScope(parameters) orelse scope;
    try stack.append(self.allocator, .{ .node = self.ast.readExtraNode(method.data.extra, ast.MethodExtra.body), .arrow_scope = .none });
    try stack.append(self.allocator, .{ .node = self.ast.readExtraNode(method.data.extra, ast.MethodExtra.params), .arrow_scope = .none });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        var arrow_scope = work.arrow_scope;
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .method_definition, .static_block, .class_declaration, .class_expression => continue,
            .arrow_function_expression => {
                arrow_scope = self.outputOwnedScope(work.node) orelse return null;
                if (arrow_scope.isNone() or arrow_scope.toIndex() >= scopes.len or scopes[arrow_scope.toIndex()].kind != .function) return null;
                if (arrow_scope == scope or (!within(scopes, arrow_scope, scope) and !within(scopes, arrow_scope, parameter_scope))) return null;
            },
            .call_expression => {
                const callee = self.ast.readExtraNode(node.data.extra, 0);
                if (!arrow_scope.isNone() and !callee.isNone() and self.ast.getNode(callee).tag == .super_expression)
                    return .{ .class_node = source, .class_scope = class_scope, .constructor_node = constructor, .constructor_scope = scope, .first_super_call = work.node, .arrow_scope = arrow_scope };
            },
            else => {},
        }
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .arrow_scope = arrow_scope });
    }
    return null;
}

fn checkSelection(source: []const u8, expected: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = @import("compat.zig").fromReactNativeVersion(0, 80) });
    t.scopes = analyzer.scopes.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.semantic_edit_enabled = true;
    var count: usize = 0;
    for (t.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const index: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
        if (try select(&t, index, node)) |plan| {
            count += 1;
            try std.testing.expectEqual(index, plan.class_node);
            try std.testing.expect(plan.class_scope != plan.constructor_scope);
            try std.testing.expect(plan.arrow_scope != plan.constructor_scope);
            try std.testing.expectEqual(ast.Node.Tag.call_expression, t.ast.getNode(plan.first_super_call).tag);
            const ctor_scope = t.outputOwnedScope(plan.constructor_node).?;
            try std.testing.expectEqual(ctor_scope, plan.constructor_scope);
            // A valid function scope of another source role cannot replace this constructor.
            try t.transformed_scope_owner_map.put(a, @backingInt(plan.constructor_node), @backingInt(plan.arrow_scope));
            try std.testing.expect((try select(&t, index, node)) == null);
            _ = t.transformed_scope_owner_map.remove(@backingInt(plan.constructor_node));
            try std.testing.expect((try select(&t, index, node)) != null);
            var foreign_class_controls: usize = 0;
            for (t.ast.nodes.items, 0..) |other, other_raw| {
                if ((other.tag != .class_declaration and other.tag != .class_expression) or other_raw == raw) continue;
                const other_scope = t.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(other_raw)))) orelse continue;
                if (other_scope != plan.class_scope) {
                    foreign_class_controls += 1;
                    try t.transformed_scope_owner_map.put(a, @intCast(raw), @backingInt(other_scope));
                    try std.testing.expect((try select(&t, index, node)) == null);
                    _ = t.transformed_scope_owner_map.remove(@intCast(raw));
                    try std.testing.expect((try select(&t, index, node)) != null);
                }
            }
            try std.testing.expect(foreign_class_controls > 0);
        }
    }
    try std.testing.expectEqual(expected, count);
}

test "RN deferred class selector ten source roles" {
    std.debug.print("RN SELECTOR START title=RN deferred class selector ten source roles sources=10\n", .{});
    const cases = [_]struct { source: []const u8, expected: usize }{
        .{ .source = "class P{}class D extends P{constructor(){const go=()=>super();go()}}", .expected = 1 },
        .{ .source = "class P{}class D extends P{constructor(){const go=()=>()=>super();go()()}}", .expected = 1 },
        .{ .source = "class P{}class D extends P{constructor(go=()=>super()){go()}}", .expected = 1 },
        .{ .source = "class P{}class D extends P{constructor(flag){const go=flag?()=>super():()=>super();go()}}", .expected = 1 },
        .{ .source = "class P{}class D extends P{constructor(){const go=()=>super();return{go}}}", .expected = 1 },
        .{ .source = "class P{}class D extends P{#value=1;constructor(){const go=()=>super();go()}}", .expected = 1 },
        .{ .source = "class P{}class D extends P{constructor(){super()}}", .expected = 0 },
        .{ .source = "class P{method(){}}class D extends P{method(){return()=>super.method()}}", .expected = 0 },
        .{ .source = "class D{method(){return()=>super.toString()}}", .expected = 0 },
        .{ .source = "class P{}class D extends P{constructor(){function make(){return class E extends P{constructor(){const go=()=>super();go()}}}super();this.E=make()}}", .expected = 1 },
    };
    for (cases) |case| try checkSelection(case.source, case.expected);
    std.debug.print("RN SELECTOR COMPLETE title=RN deferred class selector ten source roles sources={d}\n", .{cases.len});
}
