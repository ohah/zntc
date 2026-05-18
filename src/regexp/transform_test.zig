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

test "transform unicode_brace — astral → surrogate pair" {
    const o = transform.Options{ .unicode_brace = true };
    try expectTransform("\\u{1F600}", "u", o, "\\uD83D\\uDE00");
    try expectTransform("\\u{41}", "u", o, "\\u0041");
    try expectTransform("[\\u{1F600}]", "u", o, "[\\uD83D\\uDE00]");
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
