//! ast_walk.ChildIterator 유닛 테스트 — 각 DataKind 레이아웃의 자식 순회 검증.

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("parser.zig").Parser;
const ast_walk = @import("ast_walk.zig");
const ast_mod = @import("ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Node = ast_mod.Node;

/// source 를 파싱하고 root 의 node_idx 를 반환한다.
fn parseSource(allocator: std.mem.Allocator, source: []const u8) !struct { parser: Parser, scanner: Scanner } {
    var scanner = try Scanner.init(allocator, source);
    errdefer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    errdefer parser.deinit();
    _ = try parser.parse();
    return .{ .parser = parser, .scanner = scanner };
}

fn collectChildren(allocator: std.mem.Allocator, ast: *const ast_mod.Ast, idx: NodeIndex) !std.ArrayList(NodeIndex) {
    var out: std.ArrayList(NodeIndex) = .empty;
    errdefer out.deinit(allocator);
    const node = ast.getNode(idx);
    var it = ast_walk.children(ast, node);
    while (it.next()) |child| {
        try out.append(allocator, child);
    }
    return out;
}

fn findFirstTag(ast: *const ast_mod.Ast, tag: Node.Tag) ?NodeIndex {
    for (ast.nodes.items, 0..) |n, i| {
        if (n.tag == tag) return @enumFromInt(i);
    }
    return null;
}

test "ChildIterator: leaf 노드는 자식 없음" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "x;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const ref_idx = findFirstTag(&ctx.parser.ast, .identifier_reference) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, ref_idx);
    defer children.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), children.items.len);
}

test "ChildIterator: binary 노드는 left + right 반환" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "a + b;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const bin_idx = findFirstTag(&ctx.parser.ast, .binary_expression) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, bin_idx);
    defer children.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), children.items.len);

    const left_node = ctx.parser.ast.getNode(children.items[0]);
    const right_node = ctx.parser.ast.getNode(children.items[1]);
    try std.testing.expectEqual(Node.Tag.identifier_reference, left_node.tag);
    try std.testing.expectEqual(Node.Tag.identifier_reference, right_node.tag);
}

test "ChildIterator: ternary 노드는 3 개 자식" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "x ? y : z;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const cond_idx = findFirstTag(&ctx.parser.ast, .conditional_expression) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, cond_idx);
    defer children.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), children.items.len);
}

test "ChildIterator: list (program) 은 statement 개수만큼" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "a; b; c;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const prog_idx = findFirstTag(&ctx.parser.ast, .program) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, prog_idx);
    defer children.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), children.items.len);
}

test "ChildIterator: extra (variable_declaration) 은 declarator 리스트" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "let x = 1, y = 2;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const decl_idx = findFirstTag(&ctx.parser.ast, .variable_declaration) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, decl_idx);
    defer children.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), children.items.len);
    for (children.items) |c| {
        try std.testing.expectEqual(Node.Tag.variable_declarator, ctx.parser.ast.getNode(c).tag);
    }
}

test "ChildIterator: extra (call_expression) 은 callee + args" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "f(a, b, c);");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const call_idx = findFirstTag(&ctx.parser.ast, .call_expression) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, call_idx);
    defer children.deinit(a);
    // callee (f) + 3 args
    try std.testing.expectEqual(@as(usize, 4), children.items.len);
}

test "ChildIterator: unary (update) 은 operand 1개" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "x++;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const upd_idx = findFirstTag(&ctx.parser.ast, .update_expression) orelse return error.NotFound;
    var children = try collectChildren(a, &ctx.parser.ast, upd_idx);
    defer children.deinit(a);
    // update_expression 은 extra layout 이고 child_offsets=&.{0} → 1개
    try std.testing.expectEqual(@as(usize, 1), children.items.len);
}

test "ChildIterator: 같은 노드 두 번 iterate 해도 독립적 (state reset)" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "a + b;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const bin_idx = findFirstTag(&ctx.parser.ast, .binary_expression) orelse return error.NotFound;
    const node = ctx.parser.ast.getNode(bin_idx);

    var it1 = ast_walk.children(&ctx.parser.ast, node);
    var count1: usize = 0;
    while (it1.next()) |_| count1 += 1;

    var it2 = ast_walk.children(&ctx.parser.ast, node);
    var count2: usize = 0;
    while (it2.next()) |_| count2 += 1;

    try std.testing.expectEqual(count1, count2);
    try std.testing.expectEqual(@as(usize, 2), count1);
}
