//! printer.zig 라운드트립 테스트.
//!
//! 불변식: printer 는 canonical 직렬화기이므로 "바이트 동일" 이 아니라
//! **print 멱등 + 재파싱 성공** 을 검증한다.
//!   parse(p) → t1 → print → s1
//!   parse(s1) → t2 → print → s2
//!   ⇒ s1 == s2  (s1 은 printer 출력의 고정점)
//! 첫 print 가 정규화를 끝내므로 두 번째부터는 변하지 않아야 한다.

const std = @import("std");
const mod = @import("mod.zig");
const printer = @import("printer.zig");

/// p 를 flags 로 파싱→print 한 뒤, 그 결과를 다시 파싱→print 해
/// 두 번째 출력이 첫 출력과 동일(멱등)함을 확인한다.
fn expectIdempotent(p: []const u8, flag_text: []const u8) !void {
    const a = std.testing.allocator;

    var t1 = mod.parse(p, flag_text, a) orelse {
        std.debug.print("parse failed (corpus invalid): /{s}/{s}\n", .{ p, flag_text });
        return error.ParseFailed;
    };
    defer t1.deinit();
    const s1 = try printer.print(t1, a);
    defer a.free(s1);

    var t2 = mod.parse(s1, flag_text, a) orelse {
        std.debug.print("re-parse failed: /{s}/ -> /{s}/\n", .{ p, s1 });
        return error.ReParseFailed;
    };
    defer t2.deinit();
    const s2 = try printer.print(t2, a);
    defer a.free(s2);

    std.testing.expectEqualStrings(s1, s2) catch |e| {
        std.debug.print("not idempotent: /{s}/ -> '{s}' -> '{s}'\n", .{ p, s1, s2 });
        return e;
    };

    // 구조 교차검증: 멱등(s1==s2)만으로는 "lossy 하지만 안정적인" 변형
    // (예: 노드를 누락하고 그 손실된 출력이 다시 안정적으로 파싱되는 경우)을
    // 못 잡는다. canonical 입력→AST 와 그 재파싱 AST 는 노드 수·tag 열이
    // 동일해야 한다 (printer 가 노드를 누락/치환하지 않았다는 보장).
    std.testing.expectEqual(t1.nodeCount(), t2.nodeCount()) catch |e| {
        std.debug.print("node count drift: /{s}/ {d} -> '{s}' {d}\n", .{ p, t1.nodeCount(), s1, t2.nodeCount() });
        return e;
    };
    for (t1.nodes, t2.nodes, 0..) |a_node, b_node, i| {
        if (a_node.tag != b_node.tag) {
            std.debug.print("tag drift at #{d}: /{s}/ {s} -> '{s}' {s}\n", .{ i, p, @tagName(a_node.tag), s1, @tagName(b_node.tag) });
            return error.TagDrift;
        }
    }
}

/// 입력이 이미 canonical 인 경우 print 결과가 입력과 정확히 같아야 한다
/// (회귀 가드 — 정규화가 의도치 않게 모양을 바꾸지 않는지).
fn expectExact(p: []const u8, flag_text: []const u8, expected: []const u8) !void {
    const a = std.testing.allocator;
    var t = mod.parse(p, flag_text, a) orelse return error.ParseFailed;
    defer t.deinit();
    const s = try printer.print(t, a);
    defer a.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "printer roundtrip — atoms / classes / quantifiers" {
    const cases = [_][2][]const u8{
        .{ "abc", "" },
        .{ "a|b|c", "" },
        .{ "a.b", "" },
        .{ "^abc$", "" },
        .{ "\\bword\\B", "" },
        .{ "\\d\\D\\w\\W\\s\\S", "" },
        .{ "[abc]", "" },
        .{ "[^a-z0-9]", "" },
        .{ "[\\d-]", "" },
        .{ "a*", "" },
        .{ "a+?", "" },
        .{ "a??", "" },
        .{ "a{3}", "" },
        .{ "a{2,}", "" },
        .{ "a{2,5}", "" },
        .{ "a{2,5}?", "" },
        .{ "(ab)c", "" },
        .{ "(?:ab)+", "" },
        .{ "(?=ab)", "" },
        .{ "(?!ab)", "" },
        .{ "(?<=ab)", "" },
        .{ "(?<!ab)", "" },
        .{ "(?<year>\\d{4})-\\k<year>", "" },
        .{ "(a)\\1", "" },
        .{ "\\n\\r\\t\\f\\v", "" },
        .{ "[\\b]", "" }, // class 내 backspace — C1 회귀 가드
        .{ "[a\\b\\t]", "" },
        .{ "\\0", "" },
        .{ "\\x41", "" },
        .{ "\\cA", "" },
        .{ "\\.\\*\\+\\?\\(\\)\\[\\]", "" },
        .{ "a(?i:bc)d", "" },
        .{ "a(?i-m:bc)d", "" },
        .{ "\\u{1F600}", "u" },
        .{ "\\uD83D", "" },
        .{ "\\p{Letter}", "u" },
        .{ "\\P{ASCII}", "u" },
        .{ "\\p{Script=Greek}", "u" },
        .{ "\\p{Script_Extensions=Greek}", "u" },
        .{ "[\\q{abc|de}]", "v" },
        .{ "[\\w&&[a-z]]", "v" },
        .{ "[\\w--[a-z]]", "v" },
        .{ "(a|b)*c{1,3}|d", "" },
    };
    for (cases) |c| try expectIdempotent(c[0], c[1]);
}

test "printer exact — canonical input unchanged" {
    try expectExact("(?<n>ab)\\k<n>", "", "(?<n>ab)\\k<n>");
    try expectExact("[^a-z]+?", "", "[^a-z]+?");
    try expectExact("a{2,5}", "", "a{2,5}");
    try expectExact("(?:x|y)\\d*", "", "(?:x|y)\\d*");
    try expectExact("\\bfoo\\B", "", "\\bfoo\\B");
    try expectExact("(?i-s:Ab)", "", "(?i-s:Ab)");
}

test "printer exact — unicode property name=value preserved (#4413)" {
    // `\p{name=value}` 의 `=value` 가 재출력 시 보존되어야 한다. 이전엔 parser 가
    // name 범위만 노드에 저장해 `\p{Script}` 로 축약 → 런타임 SyntaxError(유효 입력
    // miscompile). 이제 프로퍼티 텍스트 전체(name..value)를 저장한다.
    try expectExact("\\p{Script=Greek}", "u", "\\p{Script=Greek}");
    try expectExact("\\P{Script=Greek}", "u", "\\P{Script=Greek}");
    try expectExact("\\p{Script_Extensions=Greek}", "u", "\\p{Script_Extensions=Greek}");
    // lone property(값 없음)는 동작 불변.
    try expectExact("\\p{Letter}", "u", "\\p{Letter}");
}

test "printer hex case — oxc canonical UPPERCASE (#1475 R2 제거)" {
    // oxc display.rs: \x{cp:02X}, \u{cp:04X} — UPPERCASE.
    // ZNTC 현 ad-hoc regex_lower 출력도 대문자(\uD83D) → 정렬 시 바이트 동일.
    try expectExact("\\xff", "", "\\xFF");
    try expectExact("\\xAb", "", "\\xAB");
    try expectExact("\\u00ab", "", "\\u00AB");
    try expectExact("\\uffff", "", "\\uFFFF");
    try expectExact("\\uD83D", "", "\\uD83D"); // lone surrogate 유지
    try expectExact("\\u{1f600}", "u", "\\u{1F600}"); // astral, brace 유지
    try expectExact("\\u{a}", "u", "\\u000A"); // ≤4 hex → \uXXXX 4자리 대문자
}

test "printer canonicalization — equivalent forms converge" {
    // {n,n} → {n}, * / + / ? 정규화 등은 멱등이면 충분.
    try expectIdempotent("a{3,3}", "");
    try expectIdempotent("a{0,}", "");
    try expectIdempotent("a{1,}", "");
    try expectIdempotent("a{0,1}", "");
}
