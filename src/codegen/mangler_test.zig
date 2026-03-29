const std = @import("std");
const mangler = @import("mangler.zig");
const base54 = mangler.base54;
const isReservedOrGlobal = mangler.isReservedOrGlobal;

test "base54: basic encoding" {
    var buf: [8]u8 = undefined;
    // 0 -> "e" (첫 번째 BASE54_CHARS 문자)
    try std.testing.expectEqualStrings("e", base54(0, &buf));
    // 1 -> "t"
    try std.testing.expectEqualStrings("t", base54(1, &buf));
    // 53 -> "$" (마지막 1글자)
    try std.testing.expectEqualStrings("$", base54(53, &buf));
    // 54 -> "ee" (2글자 시작)
    const two = base54(54, &buf);
    try std.testing.expect(two.len == 2);
    try std.testing.expect(two[0] == 'e');
}

test "base54: no reserved words in first batch" {
    var buf: [8]u8 = undefined;
    // 처음 54개 이름 중 예약어가 없는지 확인
    for (0..54) |i| {
        const name = base54(@intCast(i), &buf);
        try std.testing.expect(!isReservedOrGlobal(name));
    }
}

test "isReservedOrGlobal" {
    try std.testing.expect(isReservedOrGlobal("do"));
    try std.testing.expect(isReservedOrGlobal("if"));
    try std.testing.expect(isReservedOrGlobal("in"));
    try std.testing.expect(isReservedOrGlobal("for"));
    try std.testing.expect(isReservedOrGlobal("var"));
    try std.testing.expect(isReservedOrGlobal("null"));
    try std.testing.expect(isReservedOrGlobal("true"));
    try std.testing.expect(isReservedOrGlobal("false"));
    try std.testing.expect(isReservedOrGlobal("this"));
    try std.testing.expect(isReservedOrGlobal("void"));
    try std.testing.expect(isReservedOrGlobal("class"));
    try std.testing.expect(isReservedOrGlobal("return"));
    try std.testing.expect(!isReservedOrGlobal("a"));
    try std.testing.expect(!isReservedOrGlobal("foo"));
}
