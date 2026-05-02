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

fn collectBindingNames(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    idx: NodeIndex,
    options: ast_walk.BindingIdentifierWalker.Options,
) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it = ast_walk.bindingIdentifiers(ast, idx, options);
    while (it.next()) |leaf_idx| {
        try out.append(allocator, ast.getText(ast.getNode(leaf_idx).span));
    }
    return out;
}

test "bindingIdentifiers: simple variable declarator" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "let x = 1;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const bind_idx = findFirstTag(&ctx.parser.ast, .binding_identifier) orelse return error.NotFound;
    var names = try collectBindingNames(a, &ctx.parser.ast, bind_idx, .{});
    defer names.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), names.items.len);
    try std.testing.expectEqualStrings("x", names.items[0]);
}

test "bindingIdentifiers: array pattern with rest and default" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "let [x = 1, y, ...rest] = arr;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const arr_idx = findFirstTag(&ctx.parser.ast, .array_pattern) orelse return error.NotFound;
    var names = try collectBindingNames(a, &ctx.parser.ast, arr_idx, .{});
    defer names.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("x", names.items[0]);
    try std.testing.expectEqualStrings("y", names.items[1]);
    try std.testing.expectEqualStrings("rest", names.items[2]);
}

test "bindingIdentifiers: object pattern with shorthand and rename" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "let { a, b: c, ...rest } = obj;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const obj_idx = findFirstTag(&ctx.parser.ast, .object_pattern) orelse return error.NotFound;
    var names = try collectBindingNames(a, &ctx.parser.ast, obj_idx, .{});
    defer names.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("a", names.items[0]);
    try std.testing.expectEqualStrings("c", names.items[1]);
    try std.testing.expectEqualStrings("rest", names.items[2]);
}

test "bindingIdentifiers: formal_parameters 와 nested default" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "function f(a, b = 1, [c, d = 2], { e, f: g }) {}");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const params_idx = findFirstTag(&ctx.parser.ast, .formal_parameters) orelse return error.NotFound;
    var names = try collectBindingNames(a, &ctx.parser.ast, params_idx, .{});
    defer names.deinit(a);
    // 함수 이름 자신의 binding 은 별도 노드라 여기 들어오지 않음
    try std.testing.expectEqual(@as(usize, 6), names.items.len);
    try std.testing.expectEqualStrings("a", names.items[0]);
    try std.testing.expectEqualStrings("b", names.items[1]);
    try std.testing.expectEqualStrings("c", names.items[2]);
    try std.testing.expectEqualStrings("d", names.items[3]);
    try std.testing.expectEqualStrings("e", names.items[4]);
    try std.testing.expectEqualStrings("g", names.items[5]);
}

test "bindingIdentifiers: cover_grammar_assignment 옵션이 arrow param 의 assignment_expression 을 처리" {
    const a = std.testing.allocator;
    var ctx = try parseSource(a, "const f = (x = 1) => x;");
    defer ctx.parser.deinit();
    defer ctx.scanner.deinit();

    const params_idx = findFirstTag(&ctx.parser.ast, .formal_parameters) orelse return error.NotFound;

    // 옵션 OFF: cover-grammar 로 남은 assignment_expression 의 LHS 를 못 찾는다.
    var off = try collectBindingNames(a, &ctx.parser.ast, params_idx, .{});
    defer off.deinit(a);

    // 옵션 ON: LHS x 가 보인다.
    var on = try collectBindingNames(a, &ctx.parser.ast, params_idx, .{ .cover_grammar_assignment = true });
    defer on.deinit(a);

    // arrow cover-grammar 결과는 파서 구현에 따라 assignment_pattern 으로 정착할 수도, assignment_expression
    // 으로 남을 수도 있다. 후자라면 옵션 ON 일 때만 x 가 잡혀야 한다.
    try std.testing.expect(on.items.len >= off.items.len);
    var seen_x = false;
    for (on.items) |n| if (std.mem.eql(u8, n, "x")) {
        seen_x = true;
    };
    try std.testing.expect(seen_x);
}
