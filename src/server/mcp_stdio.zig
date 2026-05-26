//! MCP (Model Context Protocol) JSON-RPC 2.0 stdio transport.
//!
//! HTTP transport (`dev_server.handleMcp`) 와 동일한 dispatcher
//! (`DevServer.dispatchMcpRequest`) 를 newline-delimited JSON loop 으로 구동한다.
//!
//! 입력: stdin 에서 한 줄 = JSON-RPC request 한 통 (`\n` 종결).
//! 출력: stdout 에 JSON-RPC response 한 통 + `\n`.
//! EOF → 정상 종료. 빈 줄 → skip.
//!
//! `reader` / `writer` 는 generic 으로 받아 test 가 mock 주입 가능.
//! 실제 caller (NAPI entry) 는 `std.fs.File.stdin()` / `std.fs.File.stdout()`
//! 의 reader / writer 를 전달.

const std = @import("std");
const DevServer = @import("dev_server.zig").DevServer;

pub const StdioError = error{
    LineTooLong,
};

const TOO_LARGE_RESPONSE: []const u8 = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Request line too large\"},\"id\":null}";

/// stdin (reader) ← request line, stdout (writer) → response line + \n.
/// `line_buf` 는 한 줄 임시 buffer — 호출자가 64KB 정도 권장 (HTTP 와 동일 한도).
///
/// `line_buf` 초과 라인은 dispatcher 거치지 않고 `-32600 Request line too large`
/// 응답을 client 에 보낸 뒤 reader 잔여 byte 를 다음 `\n` 까지 drain → 다음 줄 정상
/// 처리 계속 (HTTP transport 의 max_body 정책과 동등).
pub fn serveStdio(
    dev_server: *DevServer,
    reader: anytype,
    writer: anytype,
    line_buf: []u8,
) !void {
    while (true) {
        const maybe_line = readLine(reader, line_buf) catch |err| switch (err) {
            StdioError.LineTooLong => {
                // 라인 너무 김 → -32600 응답 + 남은 line drain → resync.
                try writer.writeAll(TOO_LARGE_RESPONSE);
                try writer.writeByte('\n');
                try drainToNewline(reader);
                continue;
            },
            else => return err,
        };
        const line = maybe_line orelse return; // EOF
        if (line.len == 0) continue; // 빈 줄 skip

        try dev_server.dispatchMcpRequest(line, writer);
        try writer.writeByte('\n');
    }
}

/// `\n` 까지 (또는 EOF 까지) byte 를 모두 소비. LineTooLong 후 resync 용.
fn drainToNewline(reader: anytype) !void {
    var one: [1]u8 = undefined;
    while (true) {
        const n = try reader.read(&one);
        if (n == 0) return; // EOF
        if (one[0] == '\n') return;
    }
}

/// `reader` 에서 `\n` 까지 한 줄 읽기.
/// 반환:
///   - `null` — 첫 바이트 직전 EOF (정상 종료 시그널)
///   - `[]u8` slice into `buf` — 한 줄 (개행 제외)
///   - `error.LineTooLong` — `buf.len` 초과
///   - 그 외 reader error
///
/// `\r\n` 인 경우 trailing `\r` 도 제거.
fn readLine(reader: anytype, buf: []u8) !?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var one: [1]u8 = undefined;
        const n = try reader.read(&one);
        if (n == 0) {
            // EOF
            if (i == 0) return null;
            return stripTrailingCr(buf[0..i]);
        }
        const b = one[0];
        if (b == '\n') return stripTrailingCr(buf[0..i]);
        buf[i] = b;
        i += 1;
    }
    return StdioError.LineTooLong;
}

fn stripTrailingCr(line: []u8) []u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

// ─── 테스트 ───

/// 테스트용 mock reader — `[]const u8` 슬라이스를 byte 스트림으로 노출.
const MockReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn read(self: *MockReader, dst: []u8) !usize {
        if (self.pos >= self.data.len) return 0;
        const remaining = self.data.len - self.pos;
        const n = @min(dst.len, remaining);
        @memcpy(dst[0..n], self.data[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

test "readLine: single line + EOF" {
    var buf: [64]u8 = undefined;
    var mr = MockReader{ .data = "hello\n" };
    const line = try readLine(&mr, &buf);
    try std.testing.expect(line != null);
    try std.testing.expectEqualStrings("hello", line.?);

    const eof = try readLine(&mr, &buf);
    try std.testing.expectEqual(@as(?[]u8, null), eof);
}

test "readLine: CRLF normalized to LF (trailing \\r 제거)" {
    var buf: [64]u8 = undefined;
    var mr = MockReader{ .data = "hello\r\nworld\n" };
    const line1 = try readLine(&mr, &buf);
    try std.testing.expectEqualStrings("hello", line1.?);
    const line2 = try readLine(&mr, &buf);
    try std.testing.expectEqualStrings("world", line2.?);
}

test "readLine: last line without newline → returned at EOF" {
    var buf: [64]u8 = undefined;
    var mr = MockReader{ .data = "no-newline" };
    const line = try readLine(&mr, &buf);
    try std.testing.expectEqualStrings("no-newline", line.?);

    const eof = try readLine(&mr, &buf);
    try std.testing.expectEqual(@as(?[]u8, null), eof);
}

test "readLine: 빈 줄" {
    var buf: [64]u8 = undefined;
    var mr = MockReader{ .data = "\n" };
    const line = try readLine(&mr, &buf);
    try std.testing.expect(line != null);
    try std.testing.expectEqual(@as(usize, 0), line.?.len);
}

test "readLine: buf 초과 → LineTooLong" {
    var buf: [4]u8 = undefined;
    var mr = MockReader{ .data = "12345\n" };
    const result = readLine(&mr, &buf);
    try std.testing.expectError(StdioError.LineTooLong, result);
}

test "serveStdio: 단일 initialize → 한 줄 응답 + EOF 종료" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{ .root_dir = dir_path });
    defer dev_server.deinit();

    var mr = MockReader{
        .data =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
        \\
        ,
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(std.testing.allocator);
    const w = resp.writer(std.testing.allocator);

    var line_buf: [64 * 1024]u8 = undefined;
    try serveStdio(&dev_server, &mr, w, &line_buf);

    // 응답: 1줄 + 끝에 \n
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"protocolVersion\":\"2024-11-05\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":1") != null);
    try std.testing.expect(resp.items.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), resp.items[resp.items.len - 1]);
    // 정확히 1개의 newline (응답 1개)
    var nl_count: usize = 0;
    for (resp.items) |b| if (b == '\n') {
        nl_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), nl_count);
}

test "serveStdio: 여러 request 연속 처리" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{ .root_dir = dir_path });
    defer dev_server.deinit();

    var mr = MockReader{
        .data =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\
        ,
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(std.testing.allocator);
    const w = resp.writer(std.testing.allocator);

    var line_buf: [64 * 1024]u8 = undefined;
    try serveStdio(&dev_server, &mr, w, &line_buf);

    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"reset_cache\"") != null); // tools/list 응답
    // 정확히 2 개 newline (응답 2개)
    var nl_count: usize = 0;
    for (resp.items) |b| if (b == '\n') {
        nl_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), nl_count);
}

test "serveStdio: 빈 줄은 skip (응답 안 보냄)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{ .root_dir = dir_path });
    defer dev_server.deinit();

    var mr = MockReader{
        .data =
        \\
        \\
        \\{"jsonrpc":"2.0","id":7,"method":"initialize"}
        \\
        ,
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(std.testing.allocator);
    const w = resp.writer(std.testing.allocator);

    var line_buf: [64 * 1024]u8 = undefined;
    try serveStdio(&dev_server, &mr, w, &line_buf);

    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":7") != null);
    // 빈 줄 2개는 skip → 응답 1개
    var nl_count: usize = 0;
    for (resp.items) |b| if (b == '\n') {
        nl_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), nl_count);
}

test "serveStdio: tools/call reset_cache → cache_reset_requested set + 응답" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{ .root_dir = dir_path });
    defer dev_server.deinit();

    try std.testing.expectEqual(false, dev_server.cache_reset_requested.load(.acquire));

    var mr = MockReader{
        .data =
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"reset_cache","arguments":{}}}
        \\
        ,
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(std.testing.allocator);
    const w = resp.writer(std.testing.allocator);

    var line_buf: [64 * 1024]u8 = undefined;
    try serveStdio(&dev_server, &mr, w, &line_buf);

    try std.testing.expectEqual(true, dev_server.cache_reset_requested.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "Cache reset requested") != null);
}

test "serveStdio: LineTooLong → -32600 응답 + 다음 줄 정상 처리 (resync)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{ .root_dir = dir_path });
    defer dev_server.deinit();

    // 첫 줄(35 byte) 이 buf(32) 초과 → LineTooLong. 둘째 줄(21 byte) 은 buf 안에 fit
    // → unknown method 응답 (`x`). resync 검증: LineTooLong 후 다음 줄 dispatch 동작.
    var mr = MockReader{
        .data =
        \\01234567890abcdef-too-long-for-buf
        \\{"id":2,"method":"x"}
        \\
        ,
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(std.testing.allocator);
    const w = resp.writer(std.testing.allocator);

    // 의도적으로 작은 buf — 첫 줄 LineTooLong 유도, 둘째 줄은 fit.
    var line_buf: [32]u8 = undefined;
    try serveStdio(&dev_server, &mr, w, &line_buf);

    // -32600 응답 + 둘째 줄 unknown method `x` (-32601) 응답, 정상 종료.
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "-32600") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "Request line too large") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "-32601") != null);
    // 정확히 2 newline (응답 2개)
    var nl_count: usize = 0;
    for (resp.items) |b| if (b == '\n') {
        nl_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), nl_count);
}

test "serveStdio: invalid JSON 줄 → -32700 응답 후 다음 줄 처리 계속" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{ .root_dir = dir_path });
    defer dev_server.deinit();

    var mr = MockReader{
        .data =
        \\not-a-json{
        \\{"jsonrpc":"2.0","id":2,"method":"initialize"}
        \\
        ,
    };

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(std.testing.allocator);
    const w = resp.writer(std.testing.allocator);

    var line_buf: [64 * 1024]u8 = undefined;
    try serveStdio(&dev_server, &mr, w, &line_buf);

    // 첫 줄 → -32700, 둘째 줄 → initialize 응답
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.items, "\"protocolVersion\"") != null);
}
