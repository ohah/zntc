//! ZTS crash report (Bun 스타일).
//!
//! `std.debug.FullPanic`에 꽂아 쓰는 커스텀 panic 핸들러 + 신고 안내 URL 출력.
//! Phase 1 — panic handler 커스터마이징 + issue URL. POSIX signal (SIGBUS/SIGSEGV)
//! 핸들러는 async-signal-safety 검증 필요해서 후속 PR로 분리.
//!
//! 사용법 (각 root 파일에서):
//! ```zig
//! const crash_handler = @import("zts_lib").crash_handler; // CLI root는 "crash_handler.zig" 직접 import
//! pub const panic = crash_handler.panic;
//! ```
//!
//! 선택적으로 `setContext(.{ .input_file = "...", .target = "es5" })`를 진입 시 호출하면
//! panic 메시지에 컨텍스트가 함께 찍힌다. thread-local이라 스레드별 best-effort.

const std = @import("std");
const builtin = @import("builtin");

/// GitHub issue tracker base. 새 이슈 URL로 직접 보내 라벨/제목 프리필.
const ISSUE_NEW_URL = "https://github.com/ohah/zts/issues/new";

/// 진입점에서 best-effort로 채워 두는 크래시 컨텍스트.
/// panic 출력에 현재 변환 중인 파일/타겟을 포함시키기 위함.
pub const Context = struct {
    input_file: ?[]const u8 = null,
    target: ?[]const u8 = null,
    /// cli/napi/wasm 중 어디서 돌다 죽었는지.
    entry: ?[]const u8 = null,
};

threadlocal var current_context: Context = .{};

pub fn setContext(ctx: Context) void {
    current_context = ctx;
}

pub fn clearContext() void {
    current_context = .{};
}

pub fn getContext() Context {
    return current_context;
}

/// FullPanic이 요구하는 시그니처. Zig 내부에서 safety panic도 여기로 모인다.
fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    // stderr에 배너를 먼저 찍는다. 실패해도 무시 — 어쨌든 defaultPanic으로 넘어간다.
    // deprecatedWriter는 `anytype` writer를 반환하므로 std.Io.Writer 전환 이슈가 없다.
    const stderr_file = std.fs.File.stderr();
    const w = stderr_file.deprecatedWriter();
    printBanner(w, msg) catch {};

    // 기본 panic 경로 (스택 트레이스 + abort)로 위임.
    // defaultPanic은 내부에서 심볼 해석/스택 덤프 + posix.abort()를 수행.
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn printBanner(out: anytype, msg: []const u8) !void {
    try out.writeAll("\n");
    try out.print("zts: fatal: {s}\n", .{msg});

    const ctx = current_context;
    if (ctx.entry) |e| try out.print("  entry:  {s}\n", .{e});
    if (ctx.input_file) |f| try out.print("  input:  {s}\n", .{f});
    if (ctx.target) |t| try out.print("  target: {s}\n", .{t});
    try out.print("  os/arch: {s}/{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    try out.print("  zig:     {s}\n", .{builtin.zig_version_string});

    try out.writeAll(
        \\
        \\This is a bug in zts. Please file an issue with the stack trace below:
        \\
    );
    try printIssueUrl(out, msg, ctx);
    try out.writeAll("\n\n");
}

/// GitHub "new issue" URL에 title/labels 프리필.
fn printIssueUrl(out: anytype, msg: []const u8, ctx: Context) !void {
    try out.writeAll(ISSUE_NEW_URL);
    try out.writeAll("?labels=crash&title=");

    // 제목: "panic: <msg 첫 80자> (<entry>, input=<file>)"
    try writeUrlEncoded(out, "panic: ");
    const msg_cut = if (msg.len > 80) msg[0..80] else msg;
    try writeUrlEncoded(out, msg_cut);
    if (ctx.entry) |e| {
        try writeUrlEncoded(out, " (");
        try writeUrlEncoded(out, e);
        if (ctx.input_file) |f| {
            try writeUrlEncoded(out, ", input=");
            try writeUrlEncoded(out, f);
        }
        try writeUrlEncoded(out, ")");
    }
}

/// RFC3986 unreserved + 숫자/하이픈/밑줄/점/물결은 그대로, 그 외는 `%HH`.
/// 공백은 `+`로.
fn writeUrlEncoded(out: anytype, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.writeByte(c),
            ' ' => try out.writeByte('+'),
            else => {
                try out.writeByte('%');
                try out.writeByte(hex[(c >> 4) & 0xF]);
                try out.writeByte(hex[c & 0xF]);
            },
        }
    }
}

/// 진입점에서 `pub const panic = crash_handler.panic;`로 사용.
pub const panic = std.debug.FullPanic(panicFn);

// ─── 테스트 ───

test "writeUrlEncoded: unreserved passthrough + space as plus + percent encode" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeUrlEncoded(fbs.writer(), "Hello World/foo.ts");
    try std.testing.expectEqualStrings("Hello+World%2Ffoo.ts", fbs.getWritten());
}

test "setContext/getContext roundtrip" {
    setContext(.{ .input_file = "a.ts", .target = "es5", .entry = "cli" });
    const c = getContext();
    try std.testing.expectEqualStrings("a.ts", c.input_file.?);
    try std.testing.expectEqualStrings("es5", c.target.?);
    try std.testing.expectEqualStrings("cli", c.entry.?);
    clearContext();
    try std.testing.expect(getContext().input_file == null);
}
