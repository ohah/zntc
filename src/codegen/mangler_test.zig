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

// #1618: minify 모드에서 CJS 팩토리가 `$cj`로 축약. base54가 사용자 심볼에
// 동일 이름을 배정하면 preamble 정의(`var $cj=(cb,mod)=>...`)를 덮어써 CJS 런타임 파괴.
// isReservedOrGlobal에 `$cj` 등록 — nextBase54Name이 자동 skip해야 함.
test "isReservedOrGlobal: #1618 runtime helper shortened names" {
    try std.testing.expect(isReservedOrGlobal("$cj"));
    // `$c`, `$j`는 reserved가 아님 (충돌 대상이 정확히 3자 `$cj`만)
    try std.testing.expect(!isReservedOrGlobal("$c"));
    try std.testing.expect(!isReservedOrGlobal("$j"));
}

test "nextBase54Name: skips $cj" {
    const nextBase54Name = mangler.nextBase54Name;
    var buf: [8]u8 = undefined;
    var counter: u32 = 0;
    // base54에서 "$cj"가 나타나는 카운터를 모르므로 많은 이름을 생성해 검증.
    // 생성되는 이름 중 "$cj"가 절대 없어야 한다.
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        const name = nextBase54Name(&counter, &buf);
        try std.testing.expect(!std.mem.eql(u8, name, "$cj"));
    }
}

// #1618: `runtime_helpers.NAMES`의 축약 이름과 `mangler.isReservedOrGlobal`이 동기화되어야 한다.
// 향후 이름이 변경될 때 한쪽만 수정해 silent bug가 발생하지 않도록 빌드 타임에 강제.
test "runtime_helpers names are registered in mangler reserved list" {
    const rt = @import("../bundler/runtime_helpers.zig");
    try std.testing.expect(isReservedOrGlobal(rt.NAMES.CJS_FACTORY_MIN));
}
