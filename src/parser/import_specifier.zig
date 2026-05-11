//! Import specifier 추출 helper — 따옴표 제거 + JS string literal escape unescape.
//!
//! ZNTC parser 의 import / require / glob / Worker URL 등 specifier 추출 경로가
//! 공통으로 사용한다. esbuild / rolldown 처럼 ImportRecord.specifier 가 *unescape*
//! 된 byte 시퀀스를 보유하도록 보장 — Rollup/Vite 의 `\0` 가상 모듈 관례 (#3022,
//! #3025) 가 일관되게 동작한다. escape 가 없으면 raw slice 그대로 (fast path).

const std = @import("std");
const import_scanner = @import("../bundler/import_scanner.zig");

/// 따옴표 제거 + escape unescape 를 한 번에 처리한다.
/// escape 가 없으면 raw slice (alloc 없음), 있으면 allocator 로 unescape 결과 buffer 반환.
pub fn extract(allocator: std.mem.Allocator, raw: []const u8) []const u8 {
    const stripped = import_scanner.stripQuotes(raw) orelse raw;
    return unescape(allocator, stripped);
}

/// ECMAScript 12.8.4 String Literals 의 escape sequence 를 unescape 한다.
/// import specifier 는 NUL byte (Rollup/Vite `\0` 가상 모듈) 가 정상 가능하므로
/// 일반 string literal 과 달리 NUL 을 invalid 로 보지 않는다.
///
/// 처리 규칙:
///   `\0` (뒤 숫자 없음) → 0x00          `\b` → 0x08          `\t` → 0x09
///   `\n` → 0x0A         `\v` → 0x0B          `\f` → 0x0C          `\r` → 0x0D
///   `\\` `\'` `\"` → identity            `\xHH` → 0xHH (2-digit hex)
///   `\uHHHH` / `\u{H...}` → UTF-8 encoded
///   `\<LF>` / `\<CR(LF)>` → 빈 (line continuation)
///   `\1`..`\9` (legacy octal) → strip backslash, keep digits (보수적)
///   알 수 없는 `\X` → X (identity)
///
/// allocator fail 시 raw slice 반환 — parser 가 raw form 으로 계속 진행한다.
pub fn unescape(allocator: std.mem.Allocator, input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '\\') == null) return input;
    var out = std.ArrayList(u8).initCapacity(allocator, input.len) catch return input;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '\\') {
            out.append(allocator, input[i]) catch return input;
            i += 1;
            continue;
        }
        if (i + 1 >= input.len) {
            out.append(allocator, '\\') catch return input;
            i += 1;
            continue;
        }
        const next = input[i + 1];
        switch (next) {
            '0' => {
                // `\0` 뒤에 숫자가 있으면 legacy octal — 보수적으로 backslash 만 제거
                const has_digit = i + 2 < input.len and input[i + 2] >= '0' and input[i + 2] <= '9';
                if (has_digit) {
                    i += 1;
                } else {
                    out.append(allocator, 0x00) catch return input;
                    i += 2;
                }
            },
            'b' => {
                out.append(allocator, 0x08) catch return input;
                i += 2;
            },
            't' => {
                out.append(allocator, 0x09) catch return input;
                i += 2;
            },
            'n' => {
                out.append(allocator, 0x0A) catch return input;
                i += 2;
            },
            'v' => {
                out.append(allocator, 0x0B) catch return input;
                i += 2;
            },
            'f' => {
                out.append(allocator, 0x0C) catch return input;
                i += 2;
            },
            'r' => {
                out.append(allocator, 0x0D) catch return input;
                i += 2;
            },
            'x' => {
                if (i + 3 >= input.len) {
                    out.appendSlice(allocator, input[i .. i + 2]) catch return input;
                    i += 2;
                    continue;
                }
                const h1 = hexDigit(input[i + 2]) orelse {
                    out.append(allocator, next) catch return input;
                    i += 2;
                    continue;
                };
                const h2 = hexDigit(input[i + 3]) orelse {
                    out.append(allocator, next) catch return input;
                    i += 2;
                    continue;
                };
                out.append(allocator, h1 * 16 + h2) catch return input;
                i += 4;
            },
            'u' => {
                if (i + 2 < input.len and input[i + 2] == '{') {
                    var j: usize = i + 3;
                    var codepoint: u32 = 0;
                    while (j < input.len and input[j] != '}') : (j += 1) {
                        const d = hexDigit(input[j]) orelse break;
                        codepoint = codepoint * 16 + d;
                    }
                    if (j < input.len and input[j] == '}') {
                        appendCodepoint(allocator, &out, codepoint) catch return input;
                        i = j + 1;
                    } else {
                        i += 1;
                    }
                    continue;
                }
                if (i + 5 >= input.len) {
                    i += 1;
                    continue;
                }
                var codepoint: u32 = 0;
                var valid = true;
                for (input[i + 2 .. i + 6]) |c| {
                    const d = hexDigit(c) orelse {
                        valid = false;
                        break;
                    };
                    codepoint = codepoint * 16 + d;
                }
                if (valid) {
                    appendCodepoint(allocator, &out, codepoint) catch return input;
                    i += 6;
                } else {
                    i += 1;
                }
            },
            '\n' => {
                i += 2;
            },
            '\r' => {
                if (i + 2 < input.len and input[i + 2] == '\n') {
                    i += 3;
                } else {
                    i += 2;
                }
            },
            '1'...'9' => {
                i += 1;
            },
            else => {
                out.append(allocator, next) catch return input;
                i += 2;
            },
        }
    }
    return out.toOwnedSlice(allocator) catch return input;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn appendCodepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u32) !void {
    var buf: [4]u8 = undefined;
    const cp_u21: u21 = if (codepoint > std.math.maxInt(u21)) 0xFFFD else @intCast(codepoint);
    const len = std.unicode.utf8Encode(cp_u21, &buf) catch {
        try out.append(allocator, 0xEF);
        try out.append(allocator, 0xBF);
        try out.append(allocator, 0xBD);
        return;
    };
    try out.appendSlice(allocator, buf[0..len]);
}
