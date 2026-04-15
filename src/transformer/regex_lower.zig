//! Regex literal 다운레벨링 (#1387)
//!
//! esbuild 수준의 보수적 변환:
//!   - /s (dotAll, ES2018): `.` → `[\s\S]` 치환 + flag strip (완전 구현)
//!   - (?<name>...) (named capture, ES2018): `(?<name>` → `(`으로 strip
//!     → positional group으로만 보존. `match.groups` 객체는 포기.
//!   - /y (sticky, ES2015): 미지원 타겟에서 flag strip (런타임 동작 변경 있음 — 경고)
//!
//! - `u` flag + `\u{...}` brace (ES2015): `\u{X}` → surrogate pair / BMP escape + `u` flag strip (#1388)
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser.go — visitRegExpLiteral / js_lexer regex scanner
//! - TC39 Annex B / sec-patterns

const std = @import("std");
const compat = @import("compat.zig");
const unicode_escape_lower = @import("unicode_escape_lower.zig");

pub const Options = struct {
    unsupported: compat.UnsupportedFeatures,
};

pub const Result = struct {
    /// 최종 regex literal 텍스트 (`/pattern/flags` 전체). 변환이 없으면 null.
    text: ?[]const u8,
};

/// regex literal 원본 텍스트(`/pattern/flags`)를 받아 변환이 필요하면 새 슬라이스를 반환.
/// 변환이 필요 없으면 `.text = null`.
///
/// 출력 버퍼는 `allocator`로 할당. 호출자가 AST string_table 등으로 복사할 책임.
pub fn lower(allocator: std.mem.Allocator, raw: []const u8, opts: Options) !Result {
    // 최소 `/x/` 이상.
    if (raw.len < 3 or raw[0] != '/') return .{ .text = null };

    // flags 분리: 마지막 '/' 이후가 flags.
    const last_slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return .{ .text = null };
    if (last_slash == 0) return .{ .text = null };
    const pattern = raw[1..last_slash];
    const flags = raw[last_slash + 1 ..];

    const has_s = std.mem.indexOfScalar(u8, flags, 's') != null;
    const has_y = std.mem.indexOfScalar(u8, flags, 'y') != null;
    const has_u = std.mem.indexOfScalar(u8, flags, 'u') != null;

    const need_dotall = has_s and opts.unsupported.regex_dotall;
    const need_named = opts.unsupported.regex_named_groups and hasNamedGroup(pattern);
    const need_sticky = has_y and opts.unsupported.regex_sticky;
    // `u` flag 자체는 runtime 지원 대상이 아니지만, `\u{X}` brace escape 는 `u` flag 하에서만
    // 허용된다. brace escape 를 surrogate pair 로 내리면서 flag 도 함께 strip 한다.
    const need_unicode = has_u and opts.unsupported.unicode_brace_escape;

    if (!need_dotall and !need_named and !need_sticky and !need_unicode) return .{ .text = null };

    // /pattern/flags 를 단일 버퍼로 조립. dotAll/unicode 치환을 고려해 +8 여유.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw.len + 8);
    try out.append(allocator, '/');
    try rewritePattern(allocator, &out, pattern, .{
        .dotall = need_dotall,
        .strip_named = need_named,
        .unicode_brace = need_unicode,
    });
    try out.append(allocator, '/');
    for (flags) |c| {
        if (need_dotall and c == 's') continue;
        if (need_sticky and c == 'y') continue;
        if (need_unicode and c == 'u') continue;
        try out.append(allocator, c);
    }
    return .{ .text = try out.toOwnedSlice(allocator) };
}

const PatternOpts = struct {
    dotall: bool,
    strip_named: bool,
    unicode_brace: bool,
};

/// pattern 내부를 character class / escape 를 고려하며 순회하여 변환.
fn rewritePattern(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pattern: []const u8,
    opts: PatternOpts,
) !void {
    var i: usize = 0;
    var in_class: bool = false;
    while (i < pattern.len) {
        const c = pattern[i];

        // escape
        if (c == '\\') {
            // `\u{XXXX}` brace unicode escape → surrogate pair / BMP escape
            if (opts.unicode_brace and i + 2 < pattern.len and pattern[i + 1] == 'u' and pattern[i + 2] == '{') {
                if (parseBraceHex(pattern, i + 2)) |r| {
                    try appendCodepointEscape(allocator, out, r.cp);
                    i = r.end;
                    continue;
                }
            }
            try out.append(allocator, c);
            if (i + 1 < pattern.len) {
                try out.append(allocator, pattern[i + 1]);
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }

        if (in_class) {
            try out.append(allocator, c);
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }

        switch (c) {
            '[' => {
                in_class = true;
                try out.append(allocator, c);
                i += 1;
            },
            '.' => {
                if (opts.dotall) {
                    try out.appendSlice(allocator, "[\\s\\S]");
                } else {
                    try out.append(allocator, c);
                }
                i += 1;
            },
            '(' => {
                // named capture: `(?<name>...)` → `(...)`
                // non-capturing: `(?:...)` — 보존
                // lookahead/lookbehind 등도 보존.
                if (opts.strip_named and i + 2 < pattern.len and pattern[i + 1] == '?' and pattern[i + 2] == '<') {
                    // 주의: `(?<=...)` lookbehind, `(?<!...)` negative lookbehind 은 유지.
                    if (i + 3 < pattern.len and (pattern[i + 3] == '=' or pattern[i + 3] == '!')) {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    // `>`까지 skip.
                    if (std.mem.indexOfScalarPos(u8, pattern, i + 3, '>')) |gt| {
                        try out.append(allocator, '(');
                        i = gt + 1;
                        continue;
                    }
                }
                try out.append(allocator, c);
                i += 1;
            },
            else => {
                try out.append(allocator, c);
                i += 1;
            },
        }
    }
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => @as(u32, c - '0'),
        'a'...'f' => @as(u32, c - 'a' + 10),
        'A'...'F' => @as(u32, c - 'A' + 10),
        else => null,
    };
}

/// `\u{` 바로 다음의 `{` 위치를 받아 hex 를 파싱. 닫는 `}` 까지 포함한 end 반환.
fn parseBraceHex(s: []const u8, start_brace: usize) ?struct { cp: u32, end: usize } {
    var i: usize = start_brace + 1;
    var cp: u32 = 0;
    var any: bool = false;
    while (i < s.len and s[i] != '}') : (i += 1) {
        const h = hexVal(s[i]) orelse return null;
        cp = (cp << 4) | h;
        if (cp > 0x10FFFF) return null;
        any = true;
    }
    if (!any or i >= s.len or s[i] != '}') return null;
    return .{ .cp = cp, .end = i + 1 };
}

fn appendHexUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), unit: u32) !void {
    var buf: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{unit}) catch unreachable;
    try out.appendSlice(allocator, &buf);
}

fn appendCodepointEscape(allocator: std.mem.Allocator, out: *std.ArrayList(u8), cp: u32) !void {
    if (cp <= 0xFFFF) {
        try appendHexUnit(allocator, out, cp);
    } else {
        const v = cp - 0x10000;
        try appendHexUnit(allocator, out, 0xD800 | (v >> 10));
        try appendHexUnit(allocator, out, 0xDC00 | (v & 0x3FF));
    }
}

/// pattern에 `(?<name>...)` (lookbehind 제외) 가 있는지 스캔.
fn hasNamedGroup(pattern: []const u8) bool {
    var i: usize = 0;
    var in_class: bool = false;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        if (c == '[') {
            in_class = true;
            continue;
        }
        if (c == '(' and i + 2 < pattern.len and pattern[i + 1] == '?' and pattern[i + 2] == '<') {
            if (i + 3 < pattern.len and (pattern[i + 3] == '=' or pattern[i + 3] == '!')) continue;
            return true;
        }
    }
    return false;
}

// ─── 테스트 ───

const testing = std.testing;

fn runLower(raw: []const u8, unsupported: compat.UnsupportedFeatures) !?[]const u8 {
    const r = try lower(testing.allocator, raw, .{ .unsupported = unsupported });
    return r.text;
}

test "regex: dotAll /a.b/s → /a[\\s\\S]b/" {
    const out = (try runLower("/a.b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a[\\s\\S]b/", out);
}

test "regex: dotAll 이미 escape 된 . 는 변환 X" {
    const out = (try runLower("/a\\.b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a\\.b/", out);
}

test "regex: dotAll character class 안의 . 는 그대로" {
    const out = (try runLower("/[a.]b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/[a.]b/", out);
}

test "regex: dotAll 타겟이 지원 시 no-op" {
    const out = try runLower("/a.b/s", .{});
    try testing.expect(out == null);
}

test "regex: named capture → positional" {
    const out = (try runLower("/(?<year>\\d{4})/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(\\d{4})/", out);
}

test "regex: named capture 여러 개" {
    const out = (try runLower("/(?<y>\\d{4})-(?<m>\\d{2})/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(\\d{4})-(\\d{2})/", out);
}

test "regex: lookbehind (?<=...) 은 유지" {
    const out = try runLower("/(?<=a)b/", .{ .regex_named_groups = true });
    try testing.expect(out == null);
}

test "regex: sticky /y flag strip" {
    const out = (try runLower("/foo/y", .{ .regex_sticky = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/foo/", out);
}

test "regex: dotAll + sticky 함께" {
    const out = (try runLower("/a.b/sy", .{ .regex_dotall = true, .regex_sticky = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a[\\s\\S]b/", out);
}

test "regex: u + \\u{1F600} → surrogate pair + u strip" {
    const out = (try runLower("/\\u{1F600}/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\\uD83D\\uDE00/", out);
}

test "regex: u + BMP \\u{41} → \\u0041 + u strip" {
    const out = (try runLower("/\\u{41}/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\\u0041/", out);
}

test "regex: u flag 없으면 no-op" {
    const out = try runLower("/\\u0041/", .{ .unicode_brace_escape = true });
    try testing.expect(out == null);
}

test "regex: u + character class" {
    const out = (try runLower("/[\\u{1F600}]/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/[\\uD83D\\uDE00]/", out);
}

test "regex: esnext (미지원 없음) no-op" {
    const out = try runLower("/(?<year>\\d{4})/", .{});
    try testing.expect(out == null);
}
