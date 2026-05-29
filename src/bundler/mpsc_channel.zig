const std = @import("std");

/// Multi-Producer Single-Consumer 채널.
/// 여러 워커 스레드가 send()로 결과를 보내고, 메인 스레드가 recv()로 하나씩 수신.
/// 내부적으로 Mutex + Condition 기반, 큐 깊이는 스레드 풀 크기에 바운드되어 작음.
pub fn MpscChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        // 0.16: std.Thread.Mutex/Condition 제거 → std.Io.Mutex/Condition (lock/wait 가 io 요구).
        // ZNTC 는 Threaded io 백엔드라 OS 프리미티브로 동작. 내부 채널이라 cancellation 불필요
        // → lockUncancelable/waitUncancelable (구 non-erroring lock/wait 의미 보존).
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        /// 큐 저장소. send()가 뒤에 append, recv()가 앞에서 꺼냄.
        queue: std.ArrayListUnmanaged(T) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
        }

        /// 워커 스레드에서 호출. 결과를 큐에 추가하고 메인 스레드에 시그널.
        pub fn send(self: *Self, io: std.Io, item: T) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.queue.append(self.allocator, item) catch return;
            self.cond.signal(io);
        }

        /// 메인 스레드에서 호출. 큐가 비어있으면 워커가 send할 때까지 블로킹 대기.
        pub fn recv(self: *Self, io: std.Io) T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.queue.items.len == 0) {
                self.cond.waitUncancelable(io, &self.mutex);
            }
            return self.queue.swapRemove(0);
        }
    };
}
