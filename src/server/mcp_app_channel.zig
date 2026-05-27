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

/// 슬롯의 종결 상태 — `failed` 가 단일 boolean 이었던 이전 design 은 disconnect 와
/// OOM 을 구분 못 해 caller 가 wrong error 받았다 (F3). 명시 enum 으로 분리.
const SlotState = enum {
    pending,
    success, // response 있음
    disconnected, // disconnect 으로 fail
    oom, // resolveResponse 의 dupe OOM
};

/// `request` 가 wait 하는 동안 reader thread 가 채우는 슬롯. caller 가 lifetime 관리.
const PendingSlot = struct {
    /// 응답 JSON 본문 — caller allocator 로 alloc/free.
    response: ?[]const u8 = null,
    state: SlotState = .pending,
};

/// 앱 ↔ MCP server 간 WebSocket 채널의 단일 연결 상태 + pending request map.
/// 멀티 디바이스 지원은 추후 PR — 현재는 first connection wins.
pub const AppChannel = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// 별도 mutex — write_mutex 가 WS frame 송신 직렬화 + current_ws ptr lifetime 보호.
    /// reader thread 의 setCurrentWs/clearCurrentWs 가 write_mutex 잡고, inflight
    /// write 끝날 때까지 wait — `current_ws` 가 invalid 한 상태로 dispatcher 가 사용
    /// 안 됨을 보장.
    write_mutex: std.Thread.Mutex = .{},
    /// handleMcpAppWebSocket 의 stack 변수 `ws` 를 보관 — dispatcher 가 별도 인자 없이
    /// `requestStored` 호출 가능. setCurrentWs/clearCurrentWs 만 통해 변경, 모든 변경/
    /// 읽기는 write_mutex 안에서.
    current_ws: ?*http.Server.WebSocket = null,
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
            // pending → disconnected. 이미 success/oom 상태면 그대로 보존
            // (race: response 가 거의 동시에 도착했으면 caller 에게 그 결과 우선).
            if (slot_ptr.*.state == .pending) slot_ptr.*.state = .disconnected;
        }
        self.cond.broadcast();
        self.mutex.unlock();
    }

    pub fn isConnected(self: *AppChannel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connected;
    }

    /// handleMcpAppWebSocket 가 핸드셰이크 직후 호출 — dispatcher 가 ws 통해 request
    /// 가능하게 한다. clearCurrentWs 와 짝.
    pub fn setCurrentWs(self: *AppChannel, ws: *http.Server.WebSocket) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.current_ws = ws;
    }

    /// handleMcpAppWebSocket 종료 직전 (read loop 후, 함수 return 전) 호출 — ws ptr
    /// invalidation 알림. inflight write 가 있다면 write_mutex lock 으로 기다린다.
    pub fn clearCurrentWs(self: *AppChannel) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.current_ws = null;
    }

    /// stored `current_ws` 를 사용해 request 송신. dispatcher 의 production path.
    /// `request` 가 이미 `write_mutex` 안에서 writer.write 호출 — WsWriter 는 lock 잡지
    /// 않고 ws 만 호출 (nested lock 회피).
    pub fn requestStored(
        self: *AppChannel,
        method: []const u8,
        params_json: []const u8,
        timeout_ms: u64,
    ) RequestError![]const u8 {
        const WsWriter = struct {
            channel: *AppChannel,
            pub fn write(self_w: @This(), frame: []const u8) !void {
                // write_mutex 는 request 가 잡고 있음 — 여기선 ws ptr 만 read.
                // current_ws null 이면 setCurrentWs 안 됐거나 이미 clearCurrentWs 됨.
                const ws = self_w.channel.current_ws orelse return error.NotConnected;
                try ws.writeMessage(frame, .text);
            }
        };
        return self.request(method, params_json, timeout_ms, WsWriter{ .channel = self });
    }

    /// WS reader 가 response 메시지 (id + result/error) 받으면 호출. response_json 은
    /// caller 의 임시 buffer — 본 함수가 owned copy 를 만들어 slot 에 저장.
    pub fn resolveResponse(self: *AppChannel, id: u64, response_json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot_ptr = self.pending.get(id) orelse return; // orphan response — drop
        // 이미 종결됐으면 (caller 가 timeout/disconnect 으로 떠남) 새 response 무시.
        // caller stack 변수 ref 라 race window 닫음 (F1).
        if (slot_ptr.state != .pending) return;
        const copy = self.allocator.dupe(u8, response_json) catch {
            slot_ptr.state = .oom;
            self.cond.broadcast();
            return;
        };
        slot_ptr.response = copy;
        slot_ptr.state = .success;
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

        // WS frame build — main mutex 밖. write 자체는 write_mutex 로 직렬화 (F2):
        // 여러 caller 가 동시 request 호출 시 frame interleave 회피.
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);
        const w = frame.writer(self.allocator);
        std.fmt.format(w, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"", .{id}) catch return RequestError.OutOfMemory;
        // method 가 controlled (Zig 측 literal) — escape 불필요.
        w.writeAll(method) catch return RequestError.OutOfMemory;
        w.writeAll("\",\"params\":") catch return RequestError.OutOfMemory;
        w.writeAll(params_json) catch return RequestError.OutOfMemory;
        w.writeAll("}") catch return RequestError.OutOfMemory;

        self.write_mutex.lock();
        const write_result = writer.write(frame.items);
        self.write_mutex.unlock();
        write_result catch |err| {
            // WsWriter 의 `error.NotConnected` (current_ws null) 는 별도 의미. caller 가
            // "write failed" 대신 정확한 진단 받도록 분리 (F6).
            if (err == error.NotConnected) return RequestError.NotConnected;
            return RequestError.WriteFailed;
        };

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
        while (slot.state == .pending) {
            const now_i128 = std.time.nanoTimestamp();
            const now_ns: u64 = if (now_i128 > 0) @intCast(now_i128) else 0;
            if (now_ns >= deadline_ns) break; // deadline 도달 — 아래 final check
            const remaining = deadline_ns - now_ns;
            self.cond.timedWait(&self.mutex, remaining) catch {
                break; // timeout — 아래 final check
            };
        }
        // Final state 매핑 — mutex 잡은 상태에서 state 재확인. timeout race window
        // (response 가 timeout 직후 도착) 도 여기서 success 분기로 흡수해 leak/UAF 방지 (F1).
        switch (slot.state) {
            .success => return slot.response orelse RequestError.AppDisconnected,
            .disconnected => return RequestError.AppDisconnected,
            .oom => return RequestError.OutOfMemory,
            .pending => return RequestError.Timeout,
        }
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

test "AppChannel.resolveResponse: timeout 직후 도착한 응답 — slot.state 가 이미 종결이라 무시 (F1 race)" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(std.testing.allocator);
    const writer = BufWriter{ .out = &written, .alloc = std.testing.allocator };
    // 짧은 timeout — 즉시 종결.
    try std.testing.expectError(RequestError.Timeout, ch.request("late", "{}", 10, writer));
    // 정상 동작이면 pending 0 (defer 가 remove). resolveResponse 후속 호출은 orphan.
    try std.testing.expectEqual(@as(usize, 0), ch.stats().pending_count);
    ch.resolveResponse(1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"late\":true}}");
    // leak 또는 throw 없음 (testing.allocator 가 leak 검증).
}

test "AppChannel.resolveResponse: 두 동시 request — id 별 매칭, out-of-order 응답" {
    var ch = AppChannel.init(std.testing.allocator);
    defer ch.deinit();
    _ = ch.connect();

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(std.testing.allocator);

    const RunCtx = struct {
        ch: *AppChannel,
        writer: BufWriter,
        method: []const u8,
        result: ?[]const u8 = null,
        err: ?RequestError = null,

        fn run(self: *@This()) void {
            const r = self.ch.request(self.method, "{}", 2000, self.writer) catch |e| {
                self.err = e;
                return;
            };
            self.result = r;
        }
    };
    var ctx_a = RunCtx{
        .ch = &ch,
        .writer = BufWriter{ .out = &written, .alloc = std.testing.allocator },
        .method = "alpha",
    };
    var ctx_b = RunCtx{
        .ch = &ch,
        .writer = BufWriter{ .out = &written, .alloc = std.testing.allocator },
        .method = "beta",
    };
    // thread setup 을 직렬화 — 단순 sleep 만 쓰면 OS scheduler 에 따라 alpha 가 id 2,
    // beta 가 id 1 을 받아 검증 단계에서 ctx_a 가 beta 응답을 받게 됨 (race). 본 테스트의
    // 본질 (out-of-order 응답이 id 로 정확히 매칭) 은 pending 등록 후 응답 순서만
    // 뒤집어도 검증 가능 — id 할당 순서까지 굳혀 결정성 확보.
    const t_a = try std.Thread.spawn(.{}, RunCtx.run, .{&ctx_a});
    var spin: usize = 0;
    while (spin < 400 and ch.stats().pending_count < 1) : (spin += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), ch.stats().pending_count);
    const t_b = try std.Thread.spawn(.{}, RunCtx.run, .{&ctx_b});
    spin = 0;
    while (spin < 400 and ch.stats().pending_count < 2) : (spin += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), ch.stats().pending_count);

    // out-of-order: id 2 (beta) 먼저, id 1 (alpha) 나중.
    ch.resolveResponse(2, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"who\":\"beta\"}}");
    ch.resolveResponse(1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"who\":\"alpha\"}}");

    t_a.join();
    t_b.join();
    try std.testing.expect(ctx_a.result != null);
    try std.testing.expect(ctx_b.result != null);
    defer std.testing.allocator.free(ctx_a.result.?);
    defer std.testing.allocator.free(ctx_b.result.?);
    try std.testing.expect(std.mem.indexOf(u8, ctx_a.result.?, "\"alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx_b.result.?, "\"beta\"") != null);
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
