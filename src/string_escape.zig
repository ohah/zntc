//! 문자열 이스케이프 유틸리티 — JSON/JS 문자열 리터럴 공통
//!
//! 사용:
//!   const escaped = try escapeToOwned(alloc, input);
//!   defer alloc.free(escaped);
//!
//!   var buf: std.ArrayList(u8) = .empty;
//!   try appendEscaped(&buf, alloc, input);

const std = @import("std");

/// buf에 이스케이프된 문자열을 append한다 (따옴표 미포함).
/// JSON/JS 문자열 리터럴 내부에 사용.
pub fn appendEscaped(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, c),
        }
    }
}

/// 이스케이프된 문자열을 새로 할당하여 반환한다 (따옴표 미포함).
/// caller가 free해야 한다.
pub fn escapeToOwned(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try appendEscaped(&buf, alloc, input);
    return buf.toOwnedSlice(alloc);
}

pub const DecodeError = error{
    InvalidStringLiteral,
    InvalidEscape,
} || std.mem.Allocator.Error;

/// JS string literal (양 끝 따옴표 포함) 의 escape 를 모두 디코드해 owned UTF-8 로 반환.
/// `\xHH`, `\uHHHH`, `\u{H...}`, `\n \t \r \b \f \v \0`, `\\ \" \' \``,
/// line continuation 처리.
/// 에러: `error.InvalidStringLiteral` (따옴표 누락/불일치), `error.InvalidEscape`
/// (불완전 hex escape, surrogate, legacy octal 등).
pub fn decodeJsStringLiteral(alloc: std.mem.Allocator, raw_with_quotes: []const u8) DecodeError![]u8 {
    if (raw_with_quotes.len < 2) return error.InvalidStringLiteral;
    const quote = raw_with_quotes[0];
    if ((quote != '"' and quote != '\'' and quote != '`') or
        raw_with_quotes[raw_with_quotes.len - 1] != quote)
        return error.InvalidStringLiteral;

    const body = raw_with_quotes[1 .. raw_with_quotes.len - 1];
    // 99% 의 export name 은 escape 가 없어 byte-wise 디코드 루프가 무의미하다 — dupe 한 번이면 끝.
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return alloc.dupe(u8, body);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\') {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (i + 1 >= body.len) return error.InvalidEscape;
        const esc = body[i + 1];
        switch (esc) {
            'b' => {
                try out.append(alloc, 0x08);
                i += 2;
            },
            't' => {
                try out.append(alloc, 0x09);
                i += 2;
            },
            'n' => {
                try out.append(alloc, 0x0A);
                i += 2;
            },
            'v' => {
                try out.append(alloc, 0x0B);
                i += 2;
            },
            'f' => {
                try out.append(alloc, 0x0C);
                i += 2;
            },
            'r' => {
                try out.append(alloc, 0x0D);
                i += 2;
            },
            '"', '\'', '\\', '`' => {
                try out.append(alloc, esc);
                i += 2;
            },
            '0' => {
                // legacy octal (`\0` 뒤에 0-9 가 오면 octal escape) 는 거부.
                if (i + 2 < body.len and body[i + 2] >= '0' and body[i + 2] <= '9') {
                    return error.InvalidEscape;
                }
                try out.append(alloc, 0);
                i += 2;
            },
            '\n' => i += 2, // LF line continuation
            '\r' => {
                i += 2;
                if (i < body.len and body[i] == '\n') i += 1; // CRLF
            },
            'x' => {
                if (i + 4 > body.len) return error.InvalidEscape;
                const hi = std.fmt.charToDigit(body[i + 2], 16) catch return error.InvalidEscape;
                const lo = std.fmt.charToDigit(body[i + 3], 16) catch return error.InvalidEscape;
                try out.append(alloc, @intCast(hi * 16 + lo));
                i += 4;
            },
            'u' => {
                if (i + 3 > body.len) return error.InvalidEscape;
                if (body[i + 2] == '{') {
                    var j: usize = i + 3;
                    var cp: u32 = 0;
                    var any = false;
                    while (j < body.len and body[j] != '}') : (j += 1) {
                        const d = std.fmt.charToDigit(body[j], 16) catch return error.InvalidEscape;
                        cp = cp * 16 + @as(u32, d);
                        if (cp > 0x10FFFF) return error.InvalidEscape;
                        any = true;
                    }
                    if (j >= body.len or !any) return error.InvalidEscape;
                    try appendCodepoint(&out, alloc, cp);
                    i = j + 1;
                } else {
                    if (i + 6 > body.len) return error.InvalidEscape;
                    var cp: u32 = 0;
                    var k: usize = 0;
                    while (k < 4) : (k += 1) {
                        const d = std.fmt.charToDigit(body[i + 2 + k], 16) catch return error.InvalidEscape;
                        cp = cp * 16 + @as(u32, d);
                    }
                    try appendCodepoint(&out, alloc, cp);
                    i += 6;
                }
            },
            else => {
                try out.append(alloc, esc);
                i += 2;
            },
        }
    }

    return out.toOwnedSlice(alloc);
}

fn appendCodepoint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, cp: u32) DecodeError!void {
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidEscape;
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch return error.InvalidEscape;
    try out.appendSlice(alloc, buf[0..len]);
}

test "decodeJsStringLiteral basic" {
    const a = std.testing.allocator;

    {
        const got = try decodeJsStringLiteral(a, "\"used\"");
        defer a.free(got);
        try std.testing.expectEqualStrings("used", got);
    }
    {
        const got = try decodeJsStringLiteral(a, "\"u\\x73ed\"");
        defer a.free(got);
        try std.testing.expectEqualStrings("used", got);
    }
    {
        const got = try decodeJsStringLiteral(a, "\"\\u0066oo\"");
        defer a.free(got);
        try std.testing.expectEqualStrings("foo", got);
    }
    {
        const got = try decodeJsStringLiteral(a, "\"\\u{1F600}\"");
        defer a.free(got);
        try std.testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", got);
    }
    {
        const got = try decodeJsStringLiteral(a, "\"a\\nb\\tc\"");
        defer a.free(got);
        try std.testing.expectEqualStrings("a\nb\tc", got);
    }
    {
        try std.testing.expectError(error.InvalidEscape, decodeJsStringLiteral(a, "\"\\x\""));
        try std.testing.expectError(error.InvalidEscape, decodeJsStringLiteral(a, "\"\\xZZ\""));
        try std.testing.expectError(error.InvalidEscape, decodeJsStringLiteral(a, "\"\\u{}\""));
        try std.testing.expectError(error.InvalidStringLiteral, decodeJsStringLiteral(a, ""));
    }
}
