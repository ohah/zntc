//! Unicode brace escape (`\u{XXXX}`) 다운레벨링 (#1388)
//!
//! ES2015 brace unicode escape을 ES5 호환 surrogate pair 형태로 변환.
//!   - U+0000 ~ U+FFFF  → `\uXXXX`
//!   - U+10000 ~ U+10FFFF → `\uHHHH\uLLLL` (high/low surrogate)
//!
//! 적용 대상:
//!   - 문자열 리터럴 (`"..."` / `'...'`)
//!   - template literal 조각 (template_element의 raw 텍스트)
//!   - regex literal 의 `u` flag 에서의 `\u{...}` (flag strip 은 regex_lower 쪽에서)
//!
//! `\\u{...}` 처럼 backslash 자체가 escape 된 경우는 변환하지 않는다.
//! 닫는 `}` 가 없거나 16진수가 아니면 원본 유지 (lexer가 이미 검증하지만 방어적 처리).
//!
//! 참고:
//! - TC39 ECMA-262 sec-literals-string-literals (UnicodeEscapeSequence)
//! - esbuild: internal/js_printer/js_printer.go — printQuotedUTF16

const std = @import("std");

/// content에 `\u{...}` 가 하나 이상 있으면 true. 빠른 스캔 용도.
pub fn containsBraceEscape(content: []const u8) bool {
    var i: usize = 0;
    while (i + 3 < content.len) : (i += 1) {
        if (content[i] == '\\' and content[i + 1] == 'u' and content[i + 2] == '{') {
            // `\\u{` (escaped backslash) 는 제외.
            if (i > 0 and countTrailingBackslashes(content[0..i]) % 2 == 1) continue;
            return true;
        }
    }
    return false;
}

fn countTrailingBackslashes(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = s.len;
    while (i > 0 and s[i - 1] == '\\') : (i -= 1) n += 1;
    return n;
}

fn hexVal(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => @as(u32, c - '0'),
        'a'...'f' => @as(u32, c - 'a' + 10),
        'A'...'F' => @as(u32, c - 'A' + 10),
        else => null,
    };
}

/// `\u{` 가 content[pos-1] (이미 `\` 에서 시작해 pos가 'u'의 위치 + 2) 에서 시작한다고 가정하고,
/// 닫는 `}` 까지 파싱한 codepoint 와 `}` 직후 인덱스를 반환. 실패 시 null.
fn parseBraceHex(content: []const u8, start_brace: usize) ?struct { cp: u32, end: usize } {
    // content[start_brace] == '{'
    var i: usize = start_brace + 1;
    var cp: u32 = 0;
    var any: bool = false;
    while (i < content.len and content[i] != '}') : (i += 1) {
        const h = hexVal(content[i]) orelse return null;
        cp = (cp << 4) | h;
        if (cp > 0x10FFFF) return null;
        any = true;
    }
    if (!any) return null;
    if (i >= content.len or content[i] != '}') return null;
    return .{ .cp = cp, .end = i + 1 };
}

fn appendUnit(out: *std.ArrayList(u8), allocator: std.mem.Allocator, unit: u32) !void {
    var buf: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{unit}) catch unreachable;
    try out.appendSlice(allocator, &buf);
}

fn appendCodepoint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cp: u32) !void {
    if (cp <= 0xFFFF) {
        try appendUnit(out, allocator, cp);
    } else {
        // UTF-16 surrogate pair.
        const v = cp - 0x10000;
        const hi: u32 = 0xD800 | (v >> 10);
        const lo: u32 = 0xDC00 | (v & 0x3FF);
        try appendUnit(out, allocator, hi);
        try appendUnit(out, allocator, lo);
    }
}

/// content 전체에 대해 `\u{X}` 를 surrogate pair / BMP escape 로 치환.
/// 변환이 없으면 null 반환. 성공 시 owned slice 반환.
pub fn lowerContent(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    if (!containsBraceEscape(content)) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, content.len + 8);

    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\' and i + 2 < content.len and content[i + 1] == 'u' and content[i + 2] == '{') {
            if (parseBraceHex(content, i + 2)) |r| {
                try appendCodepoint(&out, allocator, r.cp);
                i = r.end;
                continue;
            }
            // 파싱 실패: 원본 `\` 복사 후 한 칸 전진.
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < content.len) {
            // escape 시퀀스는 통째로 보존 (`\\`, `\n`, `\uXXXX` 등).
            try out.append(allocator, c);
            try out.append(allocator, content[i + 1]);
            i += 2;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

// ─── 테스트 ───

const testing = std.testing;

fn expectLower(input: []const u8, expected: []const u8) !void {
    const got = (try lowerContent(testing.allocator, input)) orelse {
        try testing.expectEqualStrings(expected, input);
        return;
    };
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "unicode_escape: BMP `\\u{41}` → `\\u0041`" {
    try expectLower("\\u{41}", "\\u0041");
}

test "unicode_escape: astral `\\u{1F600}` → surrogate pair" {
    try expectLower("\\u{1F600}", "\\uD83D\\uDE00");
}

test "unicode_escape: mixed" {
    try expectLower("hi \\u{1F600}!", "hi \\uD83D\\uDE00!");
}

test "unicode_escape: no brace escape → null" {
    const got = try lowerContent(testing.allocator, "plain \\u0041 text");
    try testing.expect(got == null);
}

test "unicode_escape: `\\\\u{41}` (escaped backslash) 는 변환 X" {
    // 입력: `\\u{41}` (즉 `\u{41}` 을 문자 그대로 쓴 것)
    const got = try lowerContent(testing.allocator, "\\\\u{41}");
    try testing.expect(got == null);
}

test "unicode_escape: plain `{abc}` 영향 없음" {
    const got = try lowerContent(testing.allocator, "{abc}");
    try testing.expect(got == null);
}

test "unicode_escape: 빈 `\\u{}` 는 원본 유지" {
    // 방어적: lexer가 이미 거부하지만, 들어오면 그대로 둔다.
    try expectLower("\\u{}", "\\u{}");
}

test "unicode_escape: upper-case hex" {
    try expectLower("\\u{FF}", "\\u00FF");
}

test "unicode_escape: max codepoint 10FFFF" {
    try expectLower("\\u{10FFFF}", "\\uDBFF\\uDFFF");
}
