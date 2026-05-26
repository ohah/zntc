//! MCP app channel — Zig dev_server 와 RN 앱 안 mcp-runtime.cjs 사이의 WebSocket 채널.
//!
//! 흐름:
//!   1. RN 앱 시작 시 mcp-runtime.cjs 가 `ws://localhost:<port>/__mcp-app` 접속.
//!   2. dev_server 가 `handleMcpAppWebSocket` 으로 핸드셰이크 + 메시지 loop.
//!   3. MCP server (`zntc mcp` stdio) 가 `ping_app` / `take_snapshot` 등 tool 호출 →
//!      `AppChannel.request(method, params)` → WS 로 forward → 앱 응답 → caller 반환.
//!
//! Threading model:
//!   - WS reader thread (handleMcpAppWebSocket 의 loop): incoming 메시지 parse +
//!     response 의 경우 `resolveResponse` 호출 (pending 깨움).
//!   - Caller thread (stdio MCP dispatcher 또는 HTTP /mcp handler): `request` 가
//!     blocking — pending Map 에 등록 후 condvar 으로 wait.
//!   - 두 thread 가 같은 `*WebSocket` 의 write 접근 안 함 (caller 만 write, reader 만 read).
//!
//! 멀티 디바이스 (`deviceId` 별 라우팅) 는 추후 PR — 현재 first connection wins.

const std = @import("std");
const http = std.http;

/// 핸드셰이크 hello 메시지 — 앱 측 mcp-runtime.cjs 가 connect 확인용 parse.
/// "protocol":"mcp-app-1" 은 wire-level version negotiation 키 — 변경 시
/// JS 측 parser 도 함께 갱신 필요.
pub const HELLO_MESSAGE: []const u8 =
    "{\"jsonrpc\":\"2.0\",\"method\":\"connected\",\"params\":{\"protocol\":\"mcp-app-1\"}}";

/// First-wins 거절 시 client 에 보내는 에러. JSON-RPC 2.0 server error code (-32000)
/// 사용 — application-defined error 범위 (-32000 ~ -32099).
pub const REJECT_MESSAGE: []const u8 =
    "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"another app already connected\"}}";

pub const RequestError = error{
    NotConnected,
    Timeout,
    AppDisconnected,
    OutOfMemory,
    WriteFailed,
};

/// `request` 가 wait 하는 동안 reader thread 가 채우는 슬롯. caller 가 lifetime 관리.
const PendingSlot = struct {
    /// 응답 JSON 본문 — caller allocator 로 alloc/free.
    response: ?[]const u8 = null,
    /// `true` 면 disconnect 등으로 fail. response 는 null.
    failed: bool = false,
    completed: bool = false,
};

/// 앱 ↔ MCP server 간 WebSocket 채널의 단일 연결 상태 + pending request map.
/// 멀티 디바이스 지원은 추후 PR — 현재는 first connection wins.
pub const AppChannel = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    connected: bool = false,
    /// 핸드셰이크 누적 성공 횟수.
    connect_count: u64 = 0,
    /// 연결 끊김 누적 횟수 (성공 연결만).
    disconnect_count: u64 = 0,
    /// First-wins 거절 누적 — 같은 port 두 시뮬레이터 등 misconfig 진단용.
    reject_count: u64 = 0,
    /// JSON-RPC request id 카운터 — 0 부터 monotonic. wrap 가능성 거의 없음 (u64).
    next_request_id: u64 = 1,
    /// id → 대기 슬롯. caller 가 owns slot 의 lifetime — request 함수가 stack 에 놓고
    /// pending.put(id, slot_ptr), 응답/timeout 후 remove.
    pending: std.AutoHashMapUnmanaged(u64, *PendingSlot) = .{},

    pub fn init(allocator: std.mem.Allocator) AppChannel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppChannel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // pending request 가 남아 있으면 caller 가 이미 wait 중 — graceful 하게는 deinit 직전
        // failAllPending 호출 권장. 여기서는 map storage 만 정리 (slot 의 owner = caller).
        self.pending.deinit(self.allocator);
    }

    /// 앱이 핸드셰이크 직후 호출. first-wins.
    pub fn connect(self: *AppChannel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connected) {
            self.reject_count += 1;
            return false;
        }
        self.connected = true;
        self.connect_count += 1;
        return true;
    }

    /// WS read loop 종료 시 호출 — pending 모두 AppDisconnected 로 fail.
    pub fn disconnect(self: *AppChannel) void {
        self.mutex.lock();
        if (!self.connected) {
            self.mutex.unlock();
            return;
        }
        self.connected = false;
        self.disconnect_count += 1;

        // 모든 pending slot fail 처리 + cond broadcast 로 waiter 깨움.
        var it = self.pending.valueIterator();
        while (it.next()) |slot_ptr| {
            slot_ptr.*.failed = true;
            slot_ptr.*.completed = true;
        }
        self.cond.broadcast();
        self.mutex.unlock();
    }

    pub fn isConnected(self: *AppChannel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connected;
    }

    /// WS reader 가 response 메시지 (id + result/error) 받으면 호출. response_json 은
    /// caller 의 임시 buffer — 본 함수가 owned copy 를 만들어 slot 에 저장.
    pub fn resolveResponse(self: *AppChannel, id: u64, response_json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot_ptr = self.pending.get(id) orelse return; // orphan response — drop
        const copy = self.allocator.dupe(u8, response_json) catch {
            // OOM — slot 이 fail 처리 (response null)
            slot_ptr.failed = true;
            slot_ptr.completed = true;
            self.cond.broadcast();
            return;
        };
        slot_ptr.response = copy;
        slot_ptr.completed = true;
        self.cond.broadcast();
    }

    /// app 에 JSON-RPC request 보내고 timeout_ms 까지 response wait. 응답 본문 (full
    /// JSON-RPC response object) 을 caller-owned slice 로 반환.
    ///
    /// `params_json` 은 valid JSON Value 문자열 (예: `{"target":"foo"}` 또는 `null`).
    /// `writer` 는 `.write(frame: []const u8) !void` method 갖는 callable struct.
    /// Zig 의 stateless function 한계 회피용 — closure 가 필요한 caller (test/handler)
    /// 가 struct 안에 state (ws ptr, buffer 등) 보관.
    pub fn request(
        self: *AppChannel,
        method: []const u8,
        params_json: []const u8,
        timeout_ms: u64,
        writer: anytype,
    ) RequestError![]const u8 {
        // 연결 안 되어 있으면 즉시 fail.
        self.mutex.lock();
        if (!self.connected) {
            self.mutex.unlock();
            return RequestError.NotConnected;
        }
        const id = self.next_request_id;
        self.next_request_id += 1;
        var slot = PendingSlot{};
        self.pending.put(self.allocator, id, &slot) catch {
            self.mutex.unlock();
            return RequestError.OutOfMemory;
        };
        // pending Map 정리는 함수 종료 시.
        defer {
            self.mutex.lock();
            _ = self.pending.remove(id);
            self.mutex.unlock();
        }
        self.mutex.unlock();

        // WS frame build + 송신 (mutex 밖에서) — writer 가 caller thread 의 buffer 와
        // WebSocket output stream 사용. caller serialize 보장 (stdio 단일 thread).
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        const w = frame.writer(self.allocator);
        std.fmt.format(w, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"", .{id}) catch return RequestError.OutOfMemory;
        // method 가 controlled (Zig 측 literal) — escape 불필요.
        w.writeAll(method) catch return RequestError.OutOfMemory;
        w.writeAll("\",\"params\":") catch return RequestError.OutOfMemory;
        w.writeAll(params_json) catch return RequestError.OutOfMemory;
        w.writeAll("}") catch return RequestError.OutOfMemory;

        writer.write(frame.items) catch return RequestError.WriteFailed;

        // 응답 wait — deadline 까지 timedWait. monotonic 안 쓰는 이유: timedWait 가 relative
        // delta 받아 처리. nanoTimestamp 는 wall-clock 이라 NTP jump 시 spurious wake 가능
        // 한데, 우리 case 는 timeout 이라 잘못된 방향 (jump backward) 이면 retry, jump
        // forward 면 일찍 끝남 — 둘 다 무해.
        const start_i128 = std.time.nanoTimestamp();
        const start_ns: u64 = if (start_i128 > 0) @intCast(start_i128) else 0;
        const total_ns = timeout_ms * std.time.ns_per_ms;
        const deadline_ns = start_ns +| total_ns; // saturating add
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!slot.completed) {
            const now_i128 = std.time.nanoTimestamp();
            const now_ns: u64 = if (now_i128 > 0) @intCast(now_i128) else 0;
            if (now_ns >= deadline_ns) {
                return RequestError.Timeout;
            }
            const remaining = deadline_ns - now_ns;
            self.cond.timedWait(&self.mutex, remaining) catch {
                // timeout — slot 도 completed 안 됨. 응답 안 옴.
                return RequestError.Timeout;
            };
        }
        if (slot.failed) return RequestError.AppDisconnected;
        return slot.response orelse return RequestError.AppDisconnected;
    }

    pub fn stats(self: *AppChannel) struct {
        connected: bool,
        connect_count: u64,
        disconnect_count: u64,
        reject_count: u64,
        pending_count: usize,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .connected = self.connected,
            .connect_count = self.connect_count,
            .disconnect_count = self.disconnect_count,
            .reject_count = self.reject_count,
            .pending_count = self.pending.count(),
        };
    }
};

// ─── 테스트 ───

test "AppChannel: connect first-wins, second 가 false" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    try std.testing.expect(ch.connect());
    try std.testing.expect(!ch.connect());
    try std.testing.expect(ch.isConnected());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 1), s.connect_count);
}

test "AppChannel: disconnect 후 다시 connect 가능" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();
    ch.disconnect();
    try std.testing.expect(!ch.isConnected());
    try std.testing.expect(ch.connect());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 2), s.connect_count);
    try std.testing.expectEqual(@as(u64, 1), s.disconnect_count);
}

test "AppChannel: reject_count — 두 번째 connect 실패 시 증가, 성공한 connect 는 영향 없음" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();
    try std.testing.expectEqual(@as(u64, 0), ch.stats().reject_count);
    _ = ch.connect();
    _ = ch.connect();
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 1), s.connect_count);
    try std.testing.expectEqual(@as(u64, 2), s.reject_count);
}

test "AppChannel: 연결 안 된 상태에서 disconnect — no-op" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    ch.disconnect();
    try std.testing.expect(!ch.isConnected());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 0), s.disconnect_count);
}

test "wire contract: HELLO_MESSAGE 의 protocol 식별자 + valid JSON" {
    try std.testing.expect(std.mem.indexOf(u8, HELLO_MESSAGE, "\"protocol\":\"mcp-app-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, HELLO_MESSAGE, "\"method\":\"connected\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, HELLO_MESSAGE, .{});
    defer parsed.deinit();
}

test "wire contract: REJECT_MESSAGE — JSON-RPC error code -32000" {
    try std.testing.expect(std.mem.indexOf(u8, REJECT_MESSAGE, "-32000") != null);
    try std.testing.expect(std.mem.indexOf(u8, REJECT_MESSAGE, "another app already connected") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, REJECT_MESSAGE, .{});
    defer parsed.deinit();
}

test "AppChannel: 64 thread 동시 connect — 정확히 1개만 성공 (contended path 검증)" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();

    const Ctx = struct {
        channel: *AppChannel,
        result: bool,
        fn run(ctx: *@This()) void {
            ctx.result = ctx.channel.connect();
        }
    };

    const N = 64;
    var ctxs: [N]Ctx = undefined;
    var threads: [N]std.Thread = undefined;
    for (&ctxs) |*c| c.* = .{ .channel = &ch, .result = false };
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Ctx.run, .{&ctxs[i]});
    for (threads) |t| t.join();

    var success_count: usize = 0;
    for (ctxs) |c| if (c.result) {
        success_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), success_count);
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 1), s.connect_count);
    try std.testing.expectEqual(@as(u64, N - 1), s.reject_count);
}

const NoopWriter = struct {
    pub fn write(_: @This(), _: []const u8) !void {}
};

const BufWriter = struct {
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    pub fn write(self: @This(), frame: []const u8) !void {
        try self.out.appendSlice(self.alloc, frame);
    }
};

test "AppChannel.request: 연결 안 된 상태 → NotConnected" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    try std.testing.expectError(RequestError.NotConnected, ch.request("ping", "{}", 100, NoopWriter{}));
}

test "AppChannel.request: timeout — response 안 옴" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(std.testing.allocator);
    const writer = BufWriter{ .out = &written, .alloc = std.testing.allocator };
    try std.testing.expectError(RequestError.Timeout, ch.request("ping", "{}", 50, writer));
    // request frame 은 송신됨 (timeout 전에).
    try std.testing.expect(std.mem.indexOf(u8, written.items, "\"method\":\"ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written.items, "\"id\":1") != null);
}

test "AppChannel.request: response 도착 시 caller 반환" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(std.testing.allocator);

    const RunCtx = struct {
        ch: *AppChannel,
        writer: BufWriter,
        result: ?[]const u8 = null,
        err: ?RequestError = null,

        fn run(self: *@This()) void {
            const r = self.ch.request("ping", "{}", 1000, self.writer) catch |e| {
                self.err = e;
                return;
            };
            self.result = r;
        }
    };
    var ctx = RunCtx{
        .ch = &ch,
        .writer = BufWriter{ .out = &written, .alloc = std.testing.allocator },
    };
    const thr = try std.Thread.spawn(.{}, RunCtx.run, .{&ctx});

    // request frame 이 송신될 시간 — small sleep
    std.Thread.sleep(20 * std.time.ns_per_ms);
    // response 시뮬레이션
    ch.resolveResponse(1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"pong\":true}}");

    thr.join();
    try std.testing.expect(ctx.err == null);
    try std.testing.expect(ctx.result != null);
    defer std.testing.allocator.free(ctx.result.?);
    try std.testing.expect(std.mem.indexOf(u8, ctx.result.?, "\"pong\":true") != null);
}

test "AppChannel.request: disconnect 중 pending → AppDisconnected" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();

    const RunCtx = struct {
        ch: *AppChannel,
        err: ?RequestError = null,

        fn run(self: *@This()) void {
            const r = self.ch.request("never", "{}", 5000, NoopWriter{}) catch |e| {
                self.err = e;
                return;
            };
            std.testing.allocator.free(r);
        }
    };
    var ctx = RunCtx{ .ch = &ch };
    const thr = try std.Thread.spawn(.{}, RunCtx.run, .{&ctx});
    std.Thread.sleep(20 * std.time.ns_per_ms);
    ch.disconnect();
    thr.join();
    try std.testing.expectEqual(@as(?RequestError, RequestError.AppDisconnected), ctx.err);
}

test "AppChannel.resolveResponse: orphan id (unknown) → silent drop, throw 없음" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();
    // pending 없는 id 에 대한 response — 무시되어야 함.
    ch.resolveResponse(9999, "{\"jsonrpc\":\"2.0\",\"id\":9999,\"result\":{}}");
    // 검증: pending 0, 에러 없음
    try std.testing.expectEqual(@as(usize, 0), ch.stats().pending_count);
}
