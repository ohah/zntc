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

/// 앱 ↔ MCP server 간 WebSocket 채널의 단일 연결 상태.
/// 멀티 디바이스 지원은 추후 PR — 현재는 first connection wins.
pub const AppChannel = struct {
    mutex: std.Thread.Mutex = .{},
    connected: bool = false,
    /// 디버깅용 카운터 — 핸드셰이크 누적 횟수.
    connect_count: u64 = 0,
    /// 디버깅용 카운터 — 마지막 연결 끊김 누적 횟수.
    disconnect_count: u64 = 0,

    /// 앱이 핸드셰이크 직후 호출. 이미 다른 앱이 연결돼 있으면 `false` 반환 — caller 가
    /// 그 의미를 보고 새 연결 거절할지 (현재 first-wins) 결정.
    pub fn connect(self: *AppChannel) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connected) return false; // first-wins
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

    pub fn stats(self: *AppChannel) struct { connected: bool, connect_count: u64, disconnect_count: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .connected = self.connected,
            .connect_count = self.connect_count,
            .disconnect_count = self.disconnect_count,
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

test "AppChannel: 연결 안 된 상태에서 disconnect — no-op" {
    var ch: AppChannel = .{};
    ch.disconnect();
    try std.testing.expect(!ch.isConnected());
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 0), s.disconnect_count);
}

test "AppChannel: 동시 connect — first 만 성공 (mutex 가 race 차단)" {
    var ch: AppChannel = .{};

    const Ctx = struct {
        channel: *AppChannel,
        result: bool,
        fn run(ctx: *@This()) void {
            ctx.result = ctx.channel.connect();
        }
    };

    var a = Ctx{ .channel = &ch, .result = false };
    var b = Ctx{ .channel = &ch, .result = false };
    var t1 = try std.Thread.spawn(.{}, Ctx.run, .{&a});
    var t2 = try std.Thread.spawn(.{}, Ctx.run, .{&b});
    t1.join();
    t2.join();
    // 정확히 하나만 true
    try std.testing.expect(a.result != b.result);
    const s = ch.stats();
    try std.testing.expectEqual(@as(u64, 1), s.connect_count);
}
