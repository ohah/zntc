const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;

test "Node is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Node));
}

test "Tag fits in u16" {
    const fields = @typeInfo(Node.Tag).@"enum".fields;
    try std.testing.expect(fields.len <= 65536);
    // 현재 ~178개
    try std.testing.expect(fields.len >= 170);
}

test "NodeIndex.none" {
    const idx = NodeIndex.none;
    try std.testing.expect(idx.isNone());
    const valid: NodeIndex = @enumFromInt(0);
    try std.testing.expect(!valid.isNone());
}

test "Ast basic operations" {
    var ast = Ast.init(std.testing.allocator, "const x = 1;");
    defer ast.deinit();

    const idx = try ast.addNode(.{
        .tag = .numeric_literal,
        .span = .{ .start = 10, .end = 11 },
        .data = .{ .none = 0 },
    });

    const node = ast.getNode(idx);
    try std.testing.expectEqual(Node.Tag.numeric_literal, node.tag);
    try std.testing.expectEqualStrings("1", ast.getSourceText(node.span));
}

test "Ast node list" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const a = try ast.addNode(.{ .tag = .numeric_literal, .span = Span.EMPTY, .data = .{ .none = 0 } });
    const b = try ast.addNode(.{ .tag = .string_literal, .span = Span.EMPTY, .data = .{ .none = 0 } });

    const list = try ast.addNodeList(&.{ a, b });
    try std.testing.expectEqual(@as(u32, 2), list.len);
}

test "Ast string_table: addString + getText" {
    var ast = Ast.init(std.testing.allocator, "hello world");
    defer ast.deinit();

    // source에서 읽기 (기존 동작)
    const src_span = Span{ .start = 0, .end = 5 };
    try std.testing.expectEqualStrings("hello", ast.getText(src_span));

    // string_table에서 읽기 (합성 문자열)
    const synth_span = try ast.addString("React");
    try std.testing.expectEqualStrings("React", ast.getText(synth_span));

    // bit 31 마커 확인
    try std.testing.expect(synth_span.start & Ast.STRING_TABLE_BIT != 0);

    // 여러 합성 문자열 추가
    const span2 = try ast.addString("createElement");
    try std.testing.expectEqualStrings("createElement", ast.getText(span2));

    // 이전 span은 여전히 유효
    try std.testing.expectEqualStrings("React", ast.getText(synth_span));
}
