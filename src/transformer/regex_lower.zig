//! Regex literal 다운레벨링 (#1387)
//!
//! esbuild 수준의 보수적 변환:
//!   - /s (dotAll, ES2018): `.` → `[\s\S]` 치환 + flag strip (완전 구현)
//!   - (?<name>...) (named capture, ES2018): `(?<name>` → `(`으로 strip
//!     → positional group으로만 보존. `match.groups` 객체는 포기.
//!     `\k<name>` named backreference 도 함께 `\N` (positional)으로 변환.
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
///
/// strip_named 활성 시 named group 위치를 capture group 인덱스로 추적해
/// `\k<name>` named backreference 를 `\N` (positional)으로 함께 변환한다.
fn rewritePattern(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pattern: []const u8,
    opts: PatternOpts,
) !void {
    // 일반 패턴에서 named group은 1-3개 수준. 32 한도를 초과하면 backref 변환이
    // 누락되어 정합성이 깨지므로 silent skip 대신 assert 로 즉시 fail.
    const max_named_groups = 32;
    const NamedEntry = struct { name: []const u8, idx: u32 };
    var named: [max_named_groups]NamedEntry = undefined;
    var named_count: usize = 0;
    var group_idx: u32 = 0;

    var i: usize = 0;
    var in_class: bool = false;
    while (i < pattern.len) {
        const c = pattern[i];

        // escape
        if (c == '\\') {
            // `\u{XXXX}` brace unicode escape → surrogate pair / BMP escape
            if (opts.unicode_brace and i + 2 < pattern.len and pattern[i + 1] == 'u' and pattern[i + 2] == '{') {
                if (unicode_escape_lower.parseBraceHex(pattern, i + 2)) |r| {
                    try unicode_escape_lower.appendCodepoint(out, allocator, r.cp);
                    i = r.end;
                    continue;
                }
            }
            // `\k<name>` named backreference (character class 밖에서만 의미 있음).
            // strip_named 일 때 동일 이름의 capture group 인덱스를 찾아 `\N` 으로 치환.
            // 이름을 못 찾으면 (해당 named group이 아직 안 나옴) 원본을 보존하지만,
            // ECMAScript spec상 정상 패턴이라면 named group이 항상 먼저 정의되어 있다.
            if (!in_class and opts.strip_named and i + 2 < pattern.len and pattern[i + 1] == 'k' and pattern[i + 2] == '<') {
                if (std.mem.indexOfScalarPos(u8, pattern, i + 3, '>')) |gt| {
                    const name = pattern[i + 3 .. gt];
                    var found_idx: ?u32 = null;
                    for (named[0..named_count]) |e| {
                        if (std.mem.eql(u8, e.name, name)) {
                            found_idx = e.idx;
                            break;
                        }
                    }
                    if (found_idx) |idx| {
                        var buf: [16]u8 = undefined;
                        // u32 최대값 출력해도 11자 + '\\' = 12자 → 16바이트 버퍼로 충분.
                        const s = std.fmt.bufPrint(&buf, "\\{d}", .{idx}) catch unreachable;
                        try out.appendSlice(allocator, s);
                        i = gt + 1;
                        continue;
                    }
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
                // `(?` 로 시작하는 그룹 분류:
                //   `(?:...)` non-capturing → capture index 카운트 X
                //   `(?=...)`, `(?!...)` lookahead → capture index 카운트 X
                //   `(?<=...)`, `(?<!...)` lookbehind → capture index 카운트 X
                //   `(?<name>...)` named capture → capture index 카운트 O, strip_named 시 strip
                if (i + 2 < pattern.len and pattern[i + 1] == '?') {
                    const tag = pattern[i + 2];
                    if (tag == ':' or tag == '=' or tag == '!') {
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                    if (tag == '<') {
                        if (i + 3 < pattern.len and (pattern[i + 3] == '=' or pattern[i + 3] == '!')) {
                            try out.append(allocator, c);
                            i += 1;
                            continue;
                        }
                        group_idx += 1;
                        if (std.mem.indexOfScalarPos(u8, pattern, i + 3, '>')) |gt| {
                            std.debug.assert(named_count < max_named_groups);
                            named[named_count] = .{ .name = pattern[i + 3 .. gt], .idx = group_idx };
                            named_count += 1;
                            if (opts.strip_named) {
                                try out.append(allocator, '(');
                                i = gt + 1;
                                continue;
                            }
                        }
                        try out.append(allocator, c);
                        i += 1;
                        continue;
                    }
                }
                group_idx += 1;
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

test "regex: named backreference \\k<name> → \\N" {
    const out = (try runLower("/(?<dup>a+)b\\k<dup>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a+)b\\1/", out);
}

test "regex: named backref + 앞쪽 일반 group이 인덱스 차지" {
    const out = (try runLower("/(\\d+)-(?<word>[a-z]+)-\\k<word>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(\\d+)-([a-z]+)-\\2/", out);
}

test "regex: named backref + non-capturing group은 카운트 X" {
    const out = (try runLower("/(?:foo)(?<n>\\d+)\\k<n>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:foo)(\\d+)\\1/", out);
}

test "regex: named backref + lookbehind은 카운트 X" {
    const out = (try runLower("/(?<=\\$)(?<n>\\d+)\\k<n>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?<=\\$)(\\d+)\\1/", out);
}

test "regex: named backref — character class 안의 \\k는 그대로" {
    const out = (try runLower("/(?<n>a)[\\k<n>]/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a)[\\k<n>]/", out);
}
