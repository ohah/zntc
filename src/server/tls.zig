//! TLS adapter — BoringSSL `SSL_*` 위에 `std.Io.Reader` / `std.Io.Writer` 를 얹어
//! `std.http.Server` 가 TLS 위에서도 동작하게 한다 (#2538 4-2).
//!
//! 흐름:
//!   1. `TlsContext.init(allocator, cert_path, key_path)` — SSL_CTX + cert/key 로드
//!   2. accept 후 `TlsConnection.init(ctx, fd)` — SSL_new + SSL_set_fd + SSL_accept
//!   3. `conn.reader(buf)` / `conn.writer(buf)` → `Io.Reader` / `Io.Writer` interface
//!   4. `http.Server.init(reader.interface(), writer.interface())` 평소처럼 사용
//!   5. shutdown → `conn.deinit()` → `ctx.deinit()`
//!
//! BoringSSL `SSL_read/SSL_write` 는 internal buffer 가지므로 우리 `Io` buffer 와
//! 별개. blocking mode 라 `SSL_ERROR_WANT_READ/WRITE` 는 거의 미발생, 발생 시
//! error 로 처리 (non-blocking 은 별도 epic).

const std = @import("std");
const builtin = @import("builtin");
const boringssl = @import("boringssl.zig");

/// BoringSSL 진단 정보 — production 에서는 `std.log.err` 그대로 운영자 가시화
/// (ReleaseFast/Safe default log level=`.err` 통과). test 환경에서는 zig test
/// runner 가 `std.log.err` 호출 자체를 detection 해 `expectError` 통과 후에도
/// fail 마크. test runner 의 `std_options.logFn` override 가 사용자 root 보다
/// 우선이라 우회 불가 — `builtin.is_test` 분기로 호출 자체 skip (#2538 4-2).
const log = struct {
    fn err(comptime fmt: []const u8, args: anytype) void {
        if (builtin.is_test) return;
        std.log.err(fmt, args);
    }
};

pub const Error = error{
    SslCtxNewFailed,
    SslCtxConfigFailed,
    CertLoadFailed,
    KeyLoadFailed,
    KeyMismatch,
    SslNewFailed,
    SslSetFdFailed,
    HandshakeFailed,
    TlsRead,
    TlsWrite,
    /// Windows 의 std.posix.fd_t = HANDLE (*anyopaque) 라 boringssl 의
    /// `SSL_set_fd(c_int)` 어댑터 부재. winsock SOCKET 어댑터는 별도 epic (#3841).
    WindowsTlsUnsupported,
};

/// SSL_CTX wrapper — 1개 dev server 가 1개 context 공유. cert/key 로드는 init 시 1회.
pub const TlsContext = struct {
    ctx: *boringssl.SSL_CTX,

    pub fn init(cert_path: []const u8, key_path: []const u8) Error!TlsContext {
        const cert_z = std.posix.toPosixPath(cert_path) catch return Error.CertLoadFailed;
        const key_z = std.posix.toPosixPath(key_path) catch return Error.KeyLoadFailed;

        const ctx = boringssl.SSL_CTX_new(boringssl.TLS_server_method()) orelse return Error.SslCtxNewFailed;
        errdefer boringssl.SSL_CTX_free(ctx);

        var err_buf: [256]u8 = undefined;

        if (boringssl.SSL_CTX_set_min_proto_version(ctx, boringssl.TLS1_2_VERSION) != 1) {
            log.err("TLS: set_min_proto_version 실패: {s}", .{boringssl.lastErrorString(&err_buf)});
            return Error.SslCtxConfigFailed;
        }
        if (boringssl.SSL_CTX_set_max_proto_version(ctx, boringssl.TLS1_3_VERSION) != 1) {
            log.err("TLS: set_max_proto_version 실패: {s}", .{boringssl.lastErrorString(&err_buf)});
            return Error.SslCtxConfigFailed;
        }

        if (boringssl.SSL_CTX_use_certificate_file(ctx, &cert_z, boringssl.SSL_FILETYPE_PEM) != 1) {
            log.err("TLS: certificate '{s}' 로드 실패: {s}", .{ cert_path, boringssl.lastErrorString(&err_buf) });
            return Error.CertLoadFailed;
        }
        if (boringssl.SSL_CTX_use_PrivateKey_file(ctx, &key_z, boringssl.SSL_FILETYPE_PEM) != 1) {
            log.err("TLS: private key '{s}' 로드 실패: {s}", .{ key_path, boringssl.lastErrorString(&err_buf) });
            return Error.KeyLoadFailed;
        }
        if (boringssl.SSL_CTX_check_private_key(ctx) != 1) {
            log.err("TLS: private key 와 certificate 불일치: {s}", .{boringssl.lastErrorString(&err_buf)});
            return Error.KeyMismatch;
        }

        return .{ .ctx = ctx };
    }

    pub fn deinit(self: *TlsContext) void {
        boringssl.SSL_CTX_free(self.ctx);
    }
};

/// per-connection SSL wrapper. accept 후 1회 생성 — handshake 완료 후 reader/writer.
///
/// Platform 분기 (RFC #3833 root-cause fix, issue #3841 winsock SOCKET 어댑터):
/// Windows 의 std.posix.fd_t = HANDLE (*anyopaque) → boringssl 의 `SSL_set_fd(c_int)`
/// 에 직접 cast 불가. 사전에는 `@compileError` 로 Windows 빌드 자체 차단했으나 (PR #3842
/// 의 mitigation 까지 누적), 본 fix 는 struct 자체를 comptime 분기해 Windows 빌드
/// 통과 + runtime 시 `WindowsTlsUnsupported` error 반환. `dev_server.zig:158/434` 의
/// catch handler 가 이미 처리. winsock 어댑터 (#3841 Phase 2) 머지 시 분기 제거.
pub const TlsConnection = if (builtin.os.tag == .windows) WindowsTlsConnectionStub else PosixTlsConnection;

/// Windows 한정 stub — init 가 즉시 error 반환. reader/writer 는 init error 가드 후
/// 호출 안 되지만 type signature 만족 위해 undefined-backed stub 제공.
const WindowsTlsConnectionStub = struct {
    ssl: *boringssl.SSL,

    pub fn init(_: *TlsContext, _: std.posix.fd_t) Error!WindowsTlsConnectionStub {
        log.err("TLS adapter: Windows dev server TLS 미지원 (winsock SOCKET 어댑터 별도 epic — issue #3841).", .{});
        return Error.WindowsTlsUnsupported;
    }

    pub fn deinit(_: *WindowsTlsConnectionStub) void {}

    pub fn reader(_: *WindowsTlsConnectionStub, buffer: []u8) TlsReader {
        // init Error 후 reader 호출 unreachable — type 만족용.
        return .init(undefined, buffer);
    }

    pub fn writer(_: *WindowsTlsConnectionStub, buffer: []u8) TlsWriter {
        return .init(undefined, buffer);
    }
};

const PosixTlsConnection = struct {
    ssl: *boringssl.SSL,

    pub fn init(ctx: *TlsContext, fd: std.posix.fd_t) Error!PosixTlsConnection {
        const ssl = boringssl.SSL_new(ctx.ctx) orelse return Error.SslNewFailed;
        errdefer boringssl.SSL_free(ssl);
        if (boringssl.SSL_set_fd(ssl, @intCast(fd)) != 1) return Error.SslSetFdFailed;
        const rc = boringssl.SSL_accept(ssl);
        if (rc != 1) {
            var buf: [256]u8 = undefined;
            log.err("TLS handshake 실패: {s}", .{boringssl.lastErrorString(&buf)});
            return Error.HandshakeFailed;
        }
        return .{ .ssl = ssl };
    }

    pub fn deinit(self: *PosixTlsConnection) void {
        // graceful shutdown — 0 (진행 중) / 1 (완료) / <0 (error) 모두 cleanup 진행.
        _ = boringssl.SSL_shutdown(self.ssl);
        boringssl.SSL_free(self.ssl);
    }

    pub fn reader(self: *PosixTlsConnection, buffer: []u8) TlsReader {
        return .init(self.ssl, buffer);
    }

    pub fn writer(self: *PosixTlsConnection, buffer: []u8) TlsWriter {
        return .init(self.ssl, buffer);
    }
};

/// `std.net.Stream.Reader` 의 SSL_read 변종 — std.http.Server 가 받는 *Io.Reader 를
/// SSL 위에 박는다.
pub const TlsReader = struct {
    interface: std.Io.Reader,
    ssl: *boringssl.SSL,
    error_state: ?Error = null,

    pub fn init(ssl: *boringssl.SSL, buffer: []u8) TlsReader {
        return .{
            .interface = .{
                .vtable = &.{ .stream = streamFn },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .ssl = ssl,
        };
    }

    fn streamFn(
        io_r: *std.Io.Reader,
        io_w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *TlsReader = @alignCast(@fieldParentPtr("interface", io_r));
        return streamReadAndAdvance(io_w, limit, .{
            .ctx = self,
            .read = sslReadAdapter,
        });
    }

    fn sslReadAdapter(ctx: *anyopaque, dst: []u8) ReadResult {
        const self: *TlsReader = @ptrCast(@alignCast(ctx));
        const max: c_int = @intCast(@min(dst.len, @as(usize, std.math.maxInt(c_int))));
        const n = boringssl.SSL_read(self.ssl, dst.ptr, max);
        if (n > 0) return .{ .ok = @intCast(n) };
        const e = boringssl.SSL_get_error(self.ssl, n);
        if (e == boringssl.SSL_ERROR_ZERO_RETURN) return .end_of_stream;
        self.error_state = Error.TlsRead;
        return .failed;
    }
};

/// streamFn 의 SSL 의존 없는 generic 로직 — io_w 의 writable slice 확보 + read
/// callback 호출 + advance. drainBufferedAndData 와 동일 패턴으로 test 가능.
pub const ReadResult = union(enum) {
    ok: usize, // bytes read (>0)
    end_of_stream,
    failed,
};

pub const ReadCallback = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, dst: []u8) ReadResult,
};

pub fn streamReadAndAdvance(
    io_w: *std.Io.Writer,
    limit: std.Io.Limit,
    cb: ReadCallback,
) std.Io.Reader.StreamError!usize {
    const dst = limit.slice(try io_w.writableSliceGreedy(1));
    if (dst.len == 0) return 0;
    const result = cb.read(cb.ctx, dst);
    switch (result) {
        .ok => |n| {
            if (n == 0) return error.EndOfStream;
            io_w.advance(n);
            return n;
        },
        .end_of_stream => return error.EndOfStream,
        .failed => return error.ReadFailed,
    }
}

/// SSL_write 변종 — std.http.Server 가 받는 *Io.Writer.
pub const TlsWriter = struct {
    interface: std.Io.Writer,
    ssl: *boringssl.SSL,
    error_state: ?Error = null,

    pub fn init(ssl: *boringssl.SSL, buffer: []u8) TlsWriter {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drainFn },
                .buffer = buffer,
            },
            .ssl = ssl,
        };
    }

    fn drainFn(
        io_w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *TlsWriter = @alignCast(@fieldParentPtr("interface", io_w));
        return drainBufferedAndData(io_w, data, splat, .{
            .ctx = self,
            .write = sslWriteAdapter,
        });
    }

    fn sslWriteAdapter(ctx: *anyopaque, slice: []const u8) std.Io.Writer.Error!usize {
        const self: *TlsWriter = @ptrCast(@alignCast(ctx));
        const max: c_int = @intCast(@min(slice.len, @as(usize, std.math.maxInt(c_int))));
        const n = boringssl.SSL_write(self.ssl, slice.ptr, max);
        if (n <= 0) {
            self.error_state = Error.TlsWrite;
            return error.WriteFailed;
        }
        return @intCast(n);
    }
};

/// drainFn 의 SSL 의존 없는 generic 로직 — buffered + data + splat 처리. test
/// 에서 mock write_fn 으로 contract 검증 가능 (test backfill #2538 4-2 review).
pub const WriteCallback = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, slice: []const u8) std.Io.Writer.Error!usize,
};

pub fn drainBufferedAndData(
    io_w: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
    cb: WriteCallback,
) std.Io.Writer.Error!usize {
    // VTable.drain contract (Writer.zig L38): "Number of bytes consumed from
    // `data` is returned, excluding bytes from `buffer`." buffered 처리는
    // io_w.consume() 가 buffer end 관리 + return 값에 미포함.

    // 1. buffered (io_w.buffer[0..end]) 가 있으면 우선 처리 후 단일 호출 종료.
    // consume(n) 가 partial 시 잔여 memmove + end 갱신 + return 0.
    const buffered = io_w.buffered();
    if (buffered.len > 0) {
        const written = try cb.write(cb.ctx, buffered);
        return io_w.consume(written);
    }

    // 2. data 의 첫 (data.len-1) chunk 처리 — single 호출 후 즉시 return
    // (caller 가 다음 chunk 를 다음 drain 호출에서 받음).
    if (data.len == 0) return 0;
    for (data[0 .. data.len - 1]) |chunk| {
        if (chunk.len == 0) continue;
        return try cb.write(cb.ctx, chunk);
    }

    // 3. data 의 마지막 element 는 pattern — splat 횟수 만큼 반복. partial write
    // 시 즉시 break.
    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0) return 0;
    var written: usize = 0;
    var remaining: usize = splat;
    while (remaining > 0) : (remaining -= 1) {
        const n = try cb.write(cb.ctx, pattern);
        written += n;
        if (n < pattern.len) return written;
    }
    return written;
}

test "TlsContext: init 실패 (없는 cert 파일)" {
    const ctx_result = TlsContext.init("/nonexistent/cert.pem", "/nonexistent/key.pem");
    try std.testing.expectError(Error.CertLoadFailed, ctx_result);
}

// ─── drainBufferedAndData test (mock write callback) ────────────────────────
// PR-3a 의 /code-review max HIGH #1/#2 fix 의 직접 검증 — drain VTable contract
// 의 buffered/data/splat 처리. SSL 의존 없이 in-memory writer 로 검증.

/// drainBufferedAndData test 의 io_w 는 호출자가 io_w.vtable.drain 을 직접
/// 호출하지 않으므로 (drainBufferedAndData 가 cb.write 만 호출, vtable 미진입)
/// dummy vtable 로 충분.
const dummy_vtable: std.Io.Writer.VTable = .{
    .drain = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    }.drain,
};

const MockSink = struct {
    received: std.ArrayList(u8),
    partial_at: ?usize = null, // 누적 byte 이 이 이상이면 partial write

    fn write(ctx: *anyopaque, slice: []const u8) std.Io.Writer.Error!usize {
        const self: *MockSink = @ptrCast(@alignCast(ctx));
        const max_write = if (self.partial_at) |limit| blk: {
            if (self.received.items.len + slice.len > limit) {
                break :blk limit - self.received.items.len;
            }
            break :blk slice.len;
        } else slice.len;
        self.received.appendSlice(std.testing.allocator, slice[0..max_write]) catch return error.WriteFailed;
        return max_write;
    }
};

test "drainBufferedAndData: buffered 만 (data 빈) — io_w.consume 후 return 0" {
    var sink: MockSink = .{ .received = .empty };
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 5,
    };

    const consumed = try drainBufferedAndData(&io_w, &.{}, 0, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 0), consumed); // data 에서 consume = 0
    try std.testing.expectEqualStrings("hello", sink.received.items);
    try std.testing.expectEqual(@as(usize, 0), io_w.end); // buffer 비워짐
}

test "drainBufferedAndData: data 첫 chunk 만 — return = chunk.len, splat 의 last 미진입" {
    var sink: MockSink = .{ .received = .empty };
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 0,
    };

    const consumed = try drainBufferedAndData(&io_w, &[_][]const u8{ "abc", "_pattern" }, 3, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 3), consumed); // 첫 chunk "abc" 만
    try std.testing.expectEqualStrings("abc", sink.received.items);
}

test "drainBufferedAndData: splat 처리 — pattern N회 반복" {
    var sink: MockSink = .{ .received = .empty };
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 0,
    };

    // data = [pattern] 단일 element + splat=4 → 4회 반복
    const consumed = try drainBufferedAndData(&io_w, &[_][]const u8{"ab"}, 4, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 8), consumed); // 2 byte × 4
    try std.testing.expectEqualStrings("abababab", sink.received.items);
}

test "drainBufferedAndData: splat 중 partial write 시 즉시 break" {
    var sink: MockSink = .{ .received = .empty, .partial_at = 3 }; // 3 byte 초과 시 truncate
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 0,
    };

    // pattern "ab" + splat=4 — 1회차 "ab" (sink 2/3), 2회차 "a" 만 (partial, break)
    const consumed = try drainBufferedAndData(&io_w, &[_][]const u8{"ab"}, 4, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 3), consumed); // ab + a
    try std.testing.expectEqualStrings("aba", sink.received.items);
}

test "drainBufferedAndData: empty data + empty pattern + splat=0 → 0 return" {
    var sink: MockSink = .{ .received = .empty };
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 0,
    };

    const consumed_empty_data = try drainBufferedAndData(&io_w, &.{}, 0, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 0), consumed_empty_data);

    const consumed_empty_pattern = try drainBufferedAndData(&io_w, &[_][]const u8{""}, 5, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 0), consumed_empty_pattern);

    const consumed_zero_splat = try drainBufferedAndData(&io_w, &[_][]const u8{"x"}, 0, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 0), consumed_zero_splat);
    try std.testing.expectEqual(@as(usize, 0), sink.received.items.len);
}

// ─── streamReadAndAdvance test (mock read callback) ────────────────────────
// PR-3a 의 TlsReader.streamFn 의 SSL 의존 없는 generic 부분 검증.

const MockSource = struct {
    chunks: []const []const u8,
    index: usize = 0,
    behavior: enum { ok, end_of_stream, failed } = .ok,

    fn read(ctx: *anyopaque, dst: []u8) ReadResult {
        const self: *MockSource = @ptrCast(@alignCast(ctx));
        if (self.behavior == .end_of_stream) return .end_of_stream;
        if (self.behavior == .failed) return .failed;
        if (self.index >= self.chunks.len) return .{ .ok = 0 };
        const src = self.chunks[self.index];
        self.index += 1;
        const n = @min(src.len, dst.len);
        @memcpy(dst[0..n], src[0..n]);
        return .{ .ok = n };
    }
};

const InMemoryWriter = struct {
    writer: std.Io.Writer,

    fn init(buf: []u8) InMemoryWriter {
        return .{ .writer = .{
            .vtable = &dummy_vtable,
            .buffer = buf,
            .end = 0,
        } };
    }
};

test "streamReadAndAdvance: ok n>0 → io_w.advance(n) + return n" {
    var src: MockSource = .{ .chunks = &.{"hello"} };
    var buf: [16]u8 = undefined;
    var iw = InMemoryWriter.init(&buf);

    const n = try streamReadAndAdvance(&iw.writer, .unlimited, .{
        .ctx = &src,
        .read = MockSource.read,
    });
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(usize, 5), iw.writer.end);
    try std.testing.expectEqualStrings("hello", iw.writer.buffer[0..iw.writer.end]);
}

test "streamReadAndAdvance: end_of_stream → error.EndOfStream" {
    var src: MockSource = .{ .chunks = &.{}, .behavior = .end_of_stream };
    var buf: [16]u8 = undefined;
    var iw = InMemoryWriter.init(&buf);

    const result = streamReadAndAdvance(&iw.writer, .unlimited, .{
        .ctx = &src,
        .read = MockSource.read,
    });
    try std.testing.expectError(error.EndOfStream, result);
    try std.testing.expectEqual(@as(usize, 0), iw.writer.end); // advance 안 호출
}

test "streamReadAndAdvance: failed → error.ReadFailed" {
    var src: MockSource = .{ .chunks = &.{}, .behavior = .failed };
    var buf: [16]u8 = undefined;
    var iw = InMemoryWriter.init(&buf);

    const result = streamReadAndAdvance(&iw.writer, .unlimited, .{
        .ctx = &src,
        .read = MockSource.read,
    });
    try std.testing.expectError(error.ReadFailed, result);
}

test "streamReadAndAdvance: ok n=0 → EndOfStream (zig Io contract — 0 byte read = EOS)" {
    // MockSource 의 chunks 가 비어 .ok=0 반환 시 streamReadAndAdvance 가 EndOfStream
    // 로 변환 (read syscall 의 0 return 이 EOF 와 동일 의미).
    var src: MockSource = .{ .chunks = &.{} };
    var buf: [16]u8 = undefined;
    var iw = InMemoryWriter.init(&buf);

    const result = streamReadAndAdvance(&iw.writer, .unlimited, .{
        .ctx = &src,
        .read = MockSource.read,
    });
    try std.testing.expectError(error.EndOfStream, result);
}

test "drainBufferedAndData: buffered + data 동시 → buffered 만 처리 후 return 0 (data 미진입)" {
    var sink: MockSink = .{ .received = .empty };
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    @memcpy(buf[0..3], "AB!");
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 3,
    };

    // buffered=3 + data=[xyz] + splat=2 — drain 의 phase 1 만 발동, phase 2/3 미진입.
    // 다음 drain 호출에서 data 가 새로 들어와야 처리됨.
    const consumed = try drainBufferedAndData(&io_w, &[_][]const u8{"xyz"}, 2, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 0), consumed); // data consume = 0
    try std.testing.expectEqualStrings("AB!", sink.received.items); // buffered 만
    try std.testing.expectEqual(@as(usize, 0), io_w.end); // buffer 비워짐
}

test "drainBufferedAndData: data 중간 chunk empty → 다음 chunk 로 fall-through" {
    var sink: MockSink = .{ .received = .empty };
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 0,
    };

    // data = ["", "", "xyz", "pattern"] + splat=1
    // phase 2 (data[0..len-1] = ["", "", "xyz"]): "" 두 번 skip (continue), "xyz" 에서 단일 return.
    const consumed = try drainBufferedAndData(&io_w, &[_][]const u8{ "", "", "xyz", "pattern" }, 1, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 3), consumed); // xyz 만
    try std.testing.expectEqualStrings("xyz", sink.received.items);
}

test "drainBufferedAndData: buffered partial → io_w.consume 가 memmove + return 0" {
    var sink: MockSink = .{ .received = .empty, .partial_at = 3 }; // 3 byte 만 받음
    defer sink.received.deinit(std.testing.allocator);

    var buf: [16]u8 = undefined;
    @memcpy(buf[0..6], "hello!");
    var io_w: std.Io.Writer = .{
        .vtable = &dummy_vtable,
        .buffer = &buf,
        .end = 6,
    };

    // sink 가 "hel" 까지만 받음 → consume(3) → buf 의 "lo!" 가 [0..3] 으로 memmove + end=3
    const consumed = try drainBufferedAndData(&io_w, &.{}, 0, .{
        .ctx = &sink,
        .write = MockSink.write,
    });
    try std.testing.expectEqual(@as(usize, 0), consumed); // data 미사용
    try std.testing.expectEqualStrings("hel", sink.received.items);
    try std.testing.expectEqual(@as(usize, 3), io_w.end); // partial: 잔여 3 byte
    try std.testing.expectEqualStrings("lo!", io_w.buffer[0..io_w.end]);
}
