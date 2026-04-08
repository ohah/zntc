//! ANSI 컬러 유틸리티
//!
//! 터미널에 컬러/볼드 등 스타일을 적용하여 출력한다.
//! TTY 감지를 통해 파이프/리다이렉트 시 자동으로 컬러를 비활성화한다.
//!
//! 사용 예:
//!   const w = std.io.getStdErr().writer();
//!   try styled(w, .bold_red, "× error", true);
//!   try styled(w, .reset, "", true);

const std = @import("std");

/// ANSI 스타일. 각 항목은 ANSI escape sequence에 대응한다.
pub const Style = enum {
    reset,
    bold,
    dim,
    red,
    bold_red,
    yellow,
    bold_yellow,
    cyan,
    bold_cyan,
    green,
    bold_green,
    magenta,
    bold_magenta,
    blue,
    bold_blue,

    /// 이 스타일에 해당하는 ANSI escape code를 반환한다.
    /// 예: .bold_red → "\x1b[1;31m"
    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .bold_red => "\x1b[1;31m",
            .yellow => "\x1b[33m",
            .bold_yellow => "\x1b[1;33m",
            .cyan => "\x1b[36m",
            .bold_cyan => "\x1b[1;36m",
            .green => "\x1b[32m",
            .bold_green => "\x1b[1;32m",
            .magenta => "\x1b[35m",
            .bold_magenta => "\x1b[1;35m",
            .blue => "\x1b[34m",
            .bold_blue => "\x1b[1;34m",
        };
    }
};

/// 스타일을 적용하여 텍스트를 출력한다.
/// color_enabled=false이면 escape code 없이 텍스트만 출력한다.
///
/// 예: styled(w, .bold_red, "error", true)
///   → "\x1b[1;31merror\x1b[0m"
pub fn styled(writer: anytype, style: Style, text: []const u8, color_enabled: bool) !void {
    if (color_enabled) try writer.writeAll(style.code());
    try writer.writeAll(text);
    if (color_enabled) try writer.writeAll(Style.reset.code());
}

/// 스타일 코드만 출력한다 (텍스트 없이).
/// 이후 writeAll 등으로 텍스트를 따로 출력할 때 사용.
pub fn setStyle(writer: anytype, style: Style, color_enabled: bool) !void {
    if (color_enabled) try writer.writeAll(style.code());
}

/// 파일 디스크립터가 TTY(터미널)인지 검사한다.
/// 파이프나 리다이렉트로 출력이 연결되면 false를 반환하여
/// 컬러 코드가 파일에 섞이는 것을 방지한다.
pub fn isTty(file: std.fs.File) bool {
    return std.posix.isatty(file.handle);
}

// ─── 테스트 ───

test "Style.code returns valid ANSI sequences" {
    // 모든 스타일이 \x1b[ 로 시작하는지 확인
    const styles = [_]Style{
        .reset, .bold, .dim, .red, .bold_red,
        .yellow, .bold_yellow, .cyan, .bold_cyan,
        .green, .bold_green, .magenta, .bold_magenta,
        .blue, .bold_blue,
    };
    for (styles) |s| {
        const c = s.code();
        try std.testing.expect(c.len >= 4); // 최소 "\x1b[0m"
        try std.testing.expect(c[0] == 0x1b);
        try std.testing.expect(c[1] == '[');
    }
}

test "styled: color enabled wraps text with escape codes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try styled(w, .bold_red, "error", true);
    const out = fbs.getWritten();

    // "\x1b[1;31merror\x1b[0m"
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[1;31m"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b[0m"));
    try std.testing.expect(std.mem.indexOf(u8, out, "error") != null);
}

test "styled: color disabled outputs plain text" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try styled(w, .bold_red, "error", false);
    const out = fbs.getWritten();

    try std.testing.expectEqualStrings("error", out);
}

test "setStyle: emits only escape code" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try setStyle(w, .cyan, true);
    const out = fbs.getWritten();
    try std.testing.expectEqualStrings("\x1b[36m", out);
}

test "setStyle: no-op when color disabled" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try setStyle(w, .cyan, false);
    const out = fbs.getWritten();
    try std.testing.expectEqualStrings("", out);
}
