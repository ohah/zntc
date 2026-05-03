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

test "nodeListSplitRest" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const a = try ast.addNode(.{ .tag = .binding_identifier, .span = Span.EMPTY, .data = .{ .none = 0 } });
    const b = try ast.addNode(.{ .tag = .binding_identifier, .span = Span.EMPTY, .data = .{ .none = 0 } });
    const c = try ast.addNode(.{ .tag = .binding_identifier, .span = Span.EMPTY, .data = .{ .none = 0 } });
    const rest = try ast.addNode(.{
        .tag = .rest_element,
        .span = Span.EMPTY,
        .data = .{ .unary = .{ .operand = c, .flags = 0 } },
    });

    // case: [a, b, ...c] — rest가 마지막
    const with_rest = try ast.addNodeList(&.{ a, b, rest });
    const split_with = ast.nodeListSplitRest(with_rest);
    try std.testing.expect(split_with.rest_operand != null);
    try std.testing.expectEqual(@intFromEnum(c), @intFromEnum(split_with.rest_operand.?));
    try std.testing.expectEqual(@as(usize, 2), split_with.elements.len);

    // case: [a, b] — rest 없음
    const no_rest = try ast.addNodeList(&.{ a, b });
    const split_no = ast.nodeListSplitRest(no_rest);
    try std.testing.expect(split_no.rest_operand == null);
    try std.testing.expectEqual(@as(usize, 2), split_no.elements.len);

    // case: 빈 리스트
    const split_empty = ast.nodeListSplitRest(.{ .start = 0, .len = 0 });
    try std.testing.expect(split_empty.rest_operand == null);
    try std.testing.expectEqual(@as(usize, 0), split_empty.elements.len);

    // case: assignment_target_rest (assignment context)
    const at_rest = try ast.addNode(.{
        .tag = .assignment_target_rest,
        .span = Span.EMPTY,
        .data = .{ .unary = .{ .operand = c, .flags = 0 } },
    });
    const at_list = try ast.addNodeList(&.{ a, at_rest });
    const split_aat = ast.nodeListSplitRest(at_list);
    try std.testing.expect(split_aat.rest_operand != null);
    try std.testing.expectEqual(@intFromEnum(c), @intFromEnum(split_aat.rest_operand.?));
    try std.testing.expectEqual(@as(usize, 1), split_aat.elements.len);
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

test "Ast string_table: addString deduplicates repeated text" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const first = try ast.addString("Object");
    const second = try ast.addString("Object");
    const third = try ast.addString("defineProperty");
    const fourth = try ast.addString("Object");

    try std.testing.expectEqual(first.start, second.start);
    try std.testing.expectEqual(first.end, second.end);
    try std.testing.expectEqual(first.start, fourth.start);
    try std.testing.expectEqual(first.end, fourth.end);
    try std.testing.expect(first.start != third.start);
    try std.testing.expectEqualStrings("Object", ast.getText(first));
    try std.testing.expectEqualStrings("defineProperty", ast.getText(third));
    try std.testing.expectEqual(@as(usize, "Object".len + "defineProperty".len), ast.string_table.items.len);
}

test "Ast string_table: addString deduplicates string_table self slices" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const span = try ast.addString("React");
    const text = ast.getText(span);
    const again = try ast.addString(text);

    try std.testing.expectEqual(span.start, again.start);
    try std.testing.expectEqual(span.end, again.end);
    try std.testing.expectEqual(@as(usize, "React".len), ast.string_table.items.len);
}

test "Ast string_table: cloned AST keeps string interning table" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const original_span = try ast.addString("children");

    var cloned = try Ast.cloneForTransformer(&ast, std.testing.allocator);
    defer cloned.deinit();

    const cloned_span = try cloned.addString("children");
    const other_span = try cloned.addString("props");

    try std.testing.expectEqual(original_span.start, cloned_span.start);
    try std.testing.expectEqual(original_span.end, cloned_span.end);
    try std.testing.expectEqualStrings("children", cloned.getText(cloned_span));
    try std.testing.expectEqualStrings("props", cloned.getText(other_span));
    try std.testing.expectEqual(@as(usize, "children".len + "props".len), cloned.string_table.items.len);
}

test "Ast string_table: addString deduplicates empty string" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const first = try ast.addString("");
    const second = try ast.addString("");

    try std.testing.expectEqual(first.start, second.start);
    try std.testing.expectEqual(first.end, second.end);
    try std.testing.expectEqual(first.start, first.end);
    try std.testing.expectEqualStrings("", ast.getText(first));
    try std.testing.expectEqual(@as(usize, 0), ast.string_table.items.len);
}

test "Ast string_table: addString keeps distinct prefix and suffix strings separate" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const obj = try ast.addString("Object");
    const object_assign = try ast.addString("Object.assign");
    const assign = try ast.addString("assign");
    const obj_again = try ast.addString("Object");

    try std.testing.expectEqual(obj.start, obj_again.start);
    try std.testing.expectEqual(obj.end, obj_again.end);
    try std.testing.expect(obj.start != object_assign.start);
    try std.testing.expect(obj.start != assign.start);
    try std.testing.expect(object_assign.start != assign.start);
    try std.testing.expectEqualStrings("Object", ast.getText(obj));
    try std.testing.expectEqualStrings("Object.assign", ast.getText(object_assign));
    try std.testing.expectEqualStrings("assign", ast.getText(assign));
}

test "Ast string_table: interned spans survive later reallocations" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const stable = try ast.addString("stable");
    try ast.string_table.ensureTotalCapacity(ast.allocator, ast.string_table.items.len + 1);

    var buf: [64]u8 = undefined;
    for (0..256) |i| {
        const text = try std.fmt.bufPrint(&buf, "generated_name_{d}", .{i});
        _ = try ast.addString(text);
    }

    const stable_again = try ast.addString("stable");
    try std.testing.expectEqual(stable.start, stable_again.start);
    try std.testing.expectEqual(stable.end, stable_again.end);
    try std.testing.expectEqualStrings("stable", ast.getText(stable_again));
}

test "Ast string_table: cloned intern table is independent from source AST" {
    var ast = Ast.init(std.testing.allocator, "");

    const first = try ast.addString("shared");
    var cloned = try Ast.cloneForTransformer(&ast, std.testing.allocator);
    ast.deinit();
    defer cloned.deinit();

    const cloned_same = try cloned.addString("shared");
    const cloned_new = try cloned.addString("clone-only");

    try std.testing.expectEqual(first.start, cloned_same.start);
    try std.testing.expectEqual(first.end, cloned_same.end);
    try std.testing.expectEqualStrings("shared", cloned.getText(cloned_same));
    try std.testing.expectEqualStrings("clone-only", cloned.getText(cloned_new));
    try std.testing.expectEqual(@as(usize, "shared".len + "clone-only".len), cloned.string_table.items.len);
}
