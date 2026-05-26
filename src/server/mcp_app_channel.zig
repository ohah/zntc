//! MCP app channel — Zig dev_server 와 RN 앱 안 mcp-runtime.cjs 사이의 WebSocket 채널.
//!
//! 흐름:
//!   1. RN 앱 시작 시 mcp-runtime.cjs 가 `ws://localhost:<port>/__mcp-app` 접속.
//!   2. dev_server 가 `handleMcpAppWebSocket` 으로 핸드셰이크 + 메시지 loop.
//!   3. MCP server (`zntc mcp` stdio) 가 `take_snapshot` 같은 tool 호출 →
//!      `AppChannel.request(method, params)` → WS 로 forward → 앱 응답 → caller 반환.
//!
//! 본 PR-E1 의 범위:
//!   - `AppChannel` struct (단일 연결, mutex 보호)
//!   - `connect` / `disconnect` 라이프사이클 helper
//!   - 텍스트 메시지 echo log (디버깅용) — request/response 매칭은 후속 PR
//!
//! 멀티 디바이스 (`deviceId` 별 라우팅) 와 request/response Map 은 후속 PR-E3+ 에서 흡수.

const std = @import("std");

/// 핸드셰이크 hello 메시지 — 앱 측 mcp-runtime.cjs 가 connect 확인용 parse.
/// "protocol":"mcp-app-1" 은 wire-level version negotiation 키 — 변경 시
/// JS 측 parser 도 함께 갱신 필요.
pub const HELLO_MESSAGE: []const u8 =
    "{\"jsonrpc\":\"2.0\",\"method\":\"connected\",\"params\":{\"protocol\":\"mcp-app-1\"}}";

/// First-wins 거절 시 client 에 보내는 에러. JSON-RPC 2.0 server error code (-32000)
/// 사용 — application-defined error 범위 (-32000 ~ -32099).
pub const REJECT_MESSAGE: []const u8 =
    "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"another app already connected\"}}";

/// 앱 ↔ MCP server 간 WebSocket 채널의 단일 연결 상태.
/// 멀티 디바이스 지원은 추후 PR — 현재는 first connection wins.
pub const AppChannel = struct {
    mutex: std.Thread.Mutex = .{},
    connected: bool = false,
    /// 핸드셰이크 누적 성공 횟수.
    connect_count: u64 = 0,
    /// 연결 끊김 누적 횟수 (성공 연결만).
    disconnect_count: u64 = 0,
    /// First-wins 거절 누적 — "두 번째 디바이스가 같은 dev server 접속" 같은 misconfig
    /// 진단용. dev 환경에서 자주 0 보다 크면 같은 port 두 시뮬레이터 / RN 앱 두 개 띄움 등 hint.
    reject_count: u64 = 0,

    /// 앱이 핸드셰이크 직후 호출. 이미 다른 앱이 연결돼 있으면 `false` 반환 — caller 가
    /// 그 의미를 보고 새 연결 거절할지 (현재 first-wins) 결정.
    pub fn connect(self: *AppChannel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connected) {
            self.reject_count += 1;
            return false; // first-wins
        }
        self.connected = true;
        self.connect_count += 1;
        return true;
    }

    /// WS read loop 종료 (EOF / 에러 / 명시적 close) 시 호출.
    pub fn disconnect(self: *AppChannel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.connected) return;
        self.connected = false;
        self.disconnect_count += 1;
    }

    pub fn isConnected(self: *AppChannel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.connected;
    }

    pub fn stats(self: *AppChannel) struct {
        connected: bool,
        connect_count: u64,
        disconnect_count: u64,
        reject_count: u64,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .connected = self.connected,
            .connect_count = self.connect_count,
            .disconnect_count = self.disconnect_count,
            .reject_count = self.reject_count,
        };
    }
};

// ─── 테스트 ───

test "AppChannel: connect first-wins, second 가 false" {
    var ch: AppChannel = .{};
    try std.testing.expect(ch.connect());
    try std.testing.expect(!ch.connect());
    try std.testing.expect(ch.isConnected());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 1), s.connect_count);
}

test "AppChannel: disconnect 후 다시 connect 가능" {
    var ch: AppChannel = .{};
    _ = ch.connect();
    ch.disconnect();
    try std.testing.expect(!ch.isConnected());
    try std.testing.expect(ch.connect());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 2), s.connect_count);
    try std.testing.expectEqual(@as(u64, 1), s.disconnect_count);
}

test "AppChannel: reject_count — 두 번째 connect 실패 시 증가, 성공한 connect 는 영향 없음" {
    var ch: AppChannel = .{};
    _ = ch.connect(); // ok
    try std.testing.expectEqual(@as(u64, 0), ch.stats().reject_count);
    _ = ch.connect(); // reject
    _ = ch.connect(); // reject again
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 1), s.connect_count);
    try std.testing.expectEqual(@as(u64, 2), s.reject_count);
}

test "AppChannel: 연결 안 된 상태에서 disconnect — no-op" {
    var ch: AppChannel = .{};
    ch.disconnect();
    try std.testing.expect(!ch.isConnected());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 0), s.disconnect_count);
}

test "wire contract: HELLO_MESSAGE 의 protocol 식별자 + valid JSON" {
    // wire-level contract — JS 측 (mcp-runtime.cjs) parser 가 의존. 변경 시 PR
    // 함께 갱신하라는 회귀 잠금.
    try std.testing.expect(std.mem.indexOf(u8, HELLO_MESSAGE, "\"protocol\":\"mcp-app-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, HELLO_MESSAGE, "\"method\":\"connected\"") != null);
    // JSON parse 가능 검증
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
    // 단순 2-thread 테스트는 OS scheduler 가 t1 을 t2 보다 한참 먼저 끝내 mutex 의
    // contended path 가 거의 안 실행됨. 64 thread 로 압박해 race 진짜 검증.
    var ch: AppChannel = .{};

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
