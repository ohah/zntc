//! regexp AST transform 패스 테스트.
//!
//! 정공법 PR2(#1475): parse → AST transform → dumb printer.
//! 검증: parse(pattern,flags) → transform(opts) → printer.print == expected.
//! (babel regjsparser→AST transform→regjsgen, oxc AST→transform→Display 와 동형)

const std = @import("std");
const mod = @import("mod.zig");
const transform = @import("transform.zig");
const printer = @import("printer.zig");

fn expectTransform(
    pattern: []const u8,
    flag_text: []const u8,
    opts: transform.Options,
    expected: []const u8,
) !void {
    const a = std.testing.allocator;
    var in = mod.parse(pattern, flag_text, a) orelse return error.ParseFailed;
    defer in.deinit();

    var r = try transform.transform(in, opts, a);
    defer r.deinit();

    const out = try printer.print(r.ast, a);
    defer a.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "transform dotall — `.` (class 밖) → [\\s\\S]" {
    const o = transform.Options{ .dotall = true };
    try expectTransform("a.b", "", o, "a[\\s\\S]b");
    try expectTransform("a\\.b", "", o, "a\\.b"); // escaped dot 불변
    try expectTransform("[a.]b", "", o, "[a.]b"); // class 안 dot 불변
    try expectTransform("a.b", "", .{}, "a.b"); // opt off → no-op
}

test "transform strip_named — group unname + \\k<name> → \\N" {
    const o = transform.Options{ .strip_named = true };
    try expectTransform("(?<year>\\d{4})", "", o, "(\\d{4})");
    try expectTransform("(?<y>\\d{4})-(?<m>\\d{2})", "", o, "(\\d{4})-(\\d{2})");
    try expectTransform("(?<dup>a+)b\\k<dup>", "", o, "(a+)b\\1");
    try expectTransform("(\\d+)-(?<word>[a-z]+)-\\k<word>", "", o, "(\\d+)-([a-z]+)-\\2");
    try expectTransform("(?:foo)(?<n>\\d+)\\k<n>", "", o, "(?:foo)(\\d+)\\1");
    try expectTransform("(?<=\\$)(?<n>\\d+)\\k<n>", "", o, "(?<=\\$)(\\d+)\\1");
    // class 안 \k<n> 은 named_reference 가 아니라 identity → 불변
    try expectTransform("(?<n>a)[\\k<n>]", "", o, "(a)[\\k<n>]");
}

test "transform unicode_brace — astral atom → surrogate pair" {
    const o = transform.Options{ .unicode_brace = true };
    try expectTransform("\\u{1F600}", "u", o, "\\uD83D\\uDE00"); // 단독 atom: 그대로
    try expectTransform("\\u{41}", "u", o, "\\u0041"); // BMP
}

test "#3509 transform — positive class astral → surrogate-alternation (regexpu식)" {
    const o = transform.Options{ .unicode_brace = true };
    // 단일 astral class → (?:\uHi\uLo)
    try expectTransform("[\\u{1F600}]", "u", o, "(?:\\uD83D\\uDE00)");
    // 동일 high-surrogate range → (?:\uHi[\uLo-\uLo])  ← #3509 본 케이스
    try expectTransform("[\\u{1F600}-\\u{1F64F}]", "u", o, "(?:\\uD83D[\\uDE00-\\uDE4F])");
    // high 교차 range → alternation
    try expectTransform("[\\u{1F600}-\\u{1F900}]", "u", o, "(?:\\uD83D[\\uDE00-\\uDFFF]|\\uD83E[\\uDC00-\\uDD00])");
    // BMP + astral 혼합 → (?:[bmp]|astral-alt)
    try expectTransform("[a\\u{1F600}]", "u", o, "(?:[\\u0061]|\\uD83D\\uDE00)");
    // 전체 astral
    try expectTransform("[\\u{10000}-\\u{10FFFF}]", "u", o, "(?:[\\uD800-\\uDBFF][\\uDC00-\\uDFFF])");
}

test "#3513 negated class (non-i) → complement surrogate-alternation" {
    const o = transform.Options{ .unicode_brace = true };
    // [^a]/u = code-point 의미 → [0,0x10FFFF]-{a} complement.
    try expectTransform("[^a]", "u", o, "(?:[\\u0000-\\u0060\\u0062-\\uFFFF]|[\\uD800-\\uDBFF][\\uDC00-\\uDFFF])");
}

test "#3511 i+u case-fold — simple case-fold 등가 확장 (regexpu iuMappings 동형)" {
    const o = transform.Options{ .unicode_brace = true, .ignore_case = true };
    // [k]/iu: k + ascii K + u-전용 Kelvin(U+212A). (retained /i 가 K 처리,
    //  ZNTC 는 명시 포함 — semantic 동일, regexpu set {k,212A}).
    try expectTransform("[k]", "iu", o, "(?:[\\u004B\\u006B\\u212A])");
    // [s]/iu: s + S + ſ(U+017F).
    try expectTransform("[s]", "iu", o, "(?:[\\u0053\\u0073\\u017F])");
    // fold 무관 BMP: a + A 만 (테이블 엔트리 없음).
    try expectTransform("[a]", "iu", o, "(?:[\\u0041\\u0061])");
    // astral + i: fold 항등(emoji 무케이스) → #3509 동일.
    try expectTransform("[\\u{1F600}]", "iu", o, "(?:\\uD83D\\uDE00)");
}

test "#3511 i+u negated — fold-확장 후 complement (게이트 해제)" {
    const a = std.testing.allocator;
    // i+u negated 이제 처리됨(미변환 아님). [^k]/iu = exclude {k,K,Kelvin}.
    {
        var in = mod.parse("[^\\u{1F600}]", "iu", a) orelse return error.ParseFailed;
        defer in.deinit();
        var r = try transform.transform(in, .{ .unicode_brace = true, .ignore_case = true }, a);
        defer r.deinit();
        try std.testing.expect(!r.astral_u_incomplete); // 게이트 해제됨
    }
    // \p{}+i 는 여전히 미지원(데이터 백로그 #3512) → incomplete 유지.
    {
        var in = mod.parse("[\\p{L}\\u{1F600}]", "u", a) orelse return error.ParseFailed;
        defer in.deinit();
        var r = try transform.transform(in, .{ .unicode_brace = true }, a);
        defer r.deinit();
        try std.testing.expect(r.astral_u_incomplete);
    }
}

test "#4374 빈 character class(negated full range) → never-match (?!) (not (?:))" {
    const o = transform.Options{ .unicode_brace = true };
    // [^\u{0}-\u{10FFFF}] = 전체 범위 complement = 빈 집합 → 아무것도 매치 안 함.
    // `(?:)`(빈 문자열 매치)가 아니라 negative-lookahead-of-empty `(?!)`(never-match)여야 한다.
    try expectTransform("[^\\u{0}-\\u{10FFFF}]", "u", o, "(?!)");
}

test "#4307 v-flag intersection/subtraction class → bail (union miscompile 금지)" {
    const a = std.testing.allocator;
    const o = transform.Options{ .unicode_brace = true, .ignore_case = true };
    // [\d&&\w]/iv = 교집합 = \d. collectClassSet 이 kind 무시하면 union(\w)으로 오변환.
    // kind!=union 이면 bail → /v 보존(astral_u_incomplete) → 오변환 0.
    {
        var in = mod.parse("[\\d&&\\w]", "iv", a) orelse return error.ParseFailed;
        defer in.deinit();
        var r = try transform.transform(in, o, a);
        defer r.deinit();
        try std.testing.expect(r.astral_u_incomplete); // bail (union 으로 안 내림)
        const out = try printer.print(r.ast, a);
        defer a.free(out);
        // union 확장(\w = A-Z/a-z/_)이 새어 나오면 안 됨.
        try std.testing.expect(std.mem.indexOf(u8, out, "\\u005A") == null); // 'Z'
    }
    // [\w--\d]/iv = 차집합. 마찬가지로 bail.
    {
        var in = mod.parse("[\\w--\\d]", "iv", a) orelse return error.ParseFailed;
        defer in.deinit();
        var r = try transform.transform(in, o, a);
        defer r.deinit();
        try std.testing.expect(r.astral_u_incomplete);
    }
    // union(기본) class 는 회귀 없이 다운레벨 — bail 아님.
    {
        var in = mod.parse("[\\d]", "iv", a) orelse return error.ParseFailed;
        defer in.deinit();
        var r = try transform.transform(in, o, a);
        defer r.deinit();
        try std.testing.expect(!r.astral_u_incomplete); // 정상 처리
    }
}

test "transform 조합 — dotall + strip_named" {
    const o = transform.Options{ .dotall = true, .strip_named = true };
    try expectTransform("(?<a>.)b", "", o, "([\\s\\S])b"); // dotall 은 group 안에도 적용
    try expectTransform("(?<a>x).(?<b>y)\\k<b>", "", o, "(x)[\\s\\S](y)\\2");
}

test "transform named_groups 매핑 추출 (capture index)" {
    const a = std.testing.allocator;
    var in = mod.parse("(\\d+)-(?<word>[a-z]+)-(?<n>\\d)", "", a) orelse return error.ParseFailed;
    defer in.deinit();
    var r = try transform.transform(in, .{}, a);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.named_groups.len);
    try std.testing.expectEqualStrings("word", r.named_groups[0].name);
    try std.testing.expectEqual(@as(u32, 2), r.named_groups[0].index);
    try std.testing.expectEqualStrings("n", r.named_groups[1].name);
    try std.testing.expectEqual(@as(u32, 3), r.named_groups[1].index);
}
