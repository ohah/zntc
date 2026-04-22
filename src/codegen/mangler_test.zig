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

// #1618 / #1621: minify 모드에서 runtime helper 이름이 `$xx` 형태로 축약된다.
// base54가 사용자 심볼에 동일 이름을 배정하면 preamble 정의(`var $cj=...`, `var $tE=...`
// 등)를 덮어써 runtime 파괴. isReservedOrGlobal 에 전부 등록되어 nextBase54Name
// 가 자동 skip 해야 함.
// #1618 / #1621: runtime helper 축약 이름이 모두 mangler 예약 목록에 등록되어 있는지.
// `runtime_helpers.PAIRS` 가 단일 소스 — 빌드 타임에 순회해 drift 를 잡는다.
test "isReservedOrGlobal: all #1621 runtime helper short names registered" {
    const rt = @import("../bundler/runtime_helpers.zig");
    inline for (rt.PAIRS) |p| {
        try std.testing.expect(isReservedOrGlobal(p.short));
    }
    // 경계 케이스: 정확히 일치할 때만 reserved (prefix/suffix, case 구별).
    try std.testing.expect(!isReservedOrGlobal("$c"));
    try std.testing.expect(!isReservedOrGlobal("$j"));
    try std.testing.expect(!isReservedOrGlobal("$cjq"));
    try std.testing.expect(!isReservedOrGlobal("$te"));
    try std.testing.expect(!isReservedOrGlobal("$tc"));
    try std.testing.expect(!isReservedOrGlobal("$eX2"));
}

test "nextBase54Name: skips all runtime helper short names" {
    const rt = @import("../bundler/runtime_helpers.zig");
    const nextBase54Name = mangler.nextBase54Name;
    var buf: [8]u8 = undefined;
    var counter: u32 = 0;
    // base54 에서 각 축약 이름이 나타나는 카운터를 모르므로 많은 이름을 생성해 검증.
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        const name = nextBase54Name(&counter, &buf);
        for (rt.ALL_SHORT_NAMES) |s| {
            try std.testing.expect(!std.mem.eql(u8, name, s));
        }
    }
}

// `helperName` 분배 함수가 각 base_name 에 대해 올바른 축약 이름을 반환하는지.
// transformer 가 이 함수를 통해 AST identifier 이름을 결정하므로 정의 ↔ 매핑 drift 검증.
test "helperName: base_name → short mapping for every PAIR" {
    const rt = @import("../bundler/runtime_helpers.zig");
    inline for (rt.PAIRS) |p| {
        try std.testing.expectEqualStrings(p.base, rt.helperName(p.base, false));
        try std.testing.expectEqualStrings(p.short, rt.helperName(p.base, true));
    }
    // 알 수 없는 이름 → 원본 반환 (fallback 안전성)
    try std.testing.expectEqualStrings("__unknown", rt.helperName("__unknown", true));
}
