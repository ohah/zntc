const std = @import("std");

/// Multi-Producer Single-Consumer 채널.
/// 여러 워커 스레드가 send()로 결과를 보내고, 메인 스레드가 recv()로 하나씩 수신.
/// 내부적으로 Mutex + Condition 기반, 큐 깊이는 스레드 풀 크기에 바운드되어 작음.
pub fn MpscChannel(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
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
        pub fn send(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.queue.append(self.allocator, item) catch return;
            self.cond.signal();
        }

        /// 메인 스레드에서 호출. 큐가 비어있으면 워커가 send할 때까지 블로킹 대기.
        pub fn recv(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.queue.items.len == 0) {
                self.cond.wait(&self.mutex);
            }
            return self.queue.swapRemove(0);
        }
    };
}
