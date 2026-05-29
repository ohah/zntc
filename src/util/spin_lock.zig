//! io-free 스핀락 (Zig 0.16 마이그레이션).
//!
//! Zig 0.16 에서 `std.Thread.Mutex`/`Condition`/`RwLock` 이 제거되고 `std.Io.Mutex`
//! 등으로 대체됐는데, `std.Io.Mutex.lock(io)` 는 **io 인자를 요구**한다 (blocking 시
//! io 스케줄러에 양보 가능하도록). 그러나 번들러의 동시성 구조 대부분은 임계구역이
//! 짧은 HashMap get/put 이거나, double-check 패턴으로 실제 I/O 를 락 *밖* 에서 수행해
//! 락 안에서는 blocking 하지 않는다. 그런 곳에 io 를 스레딩하는 것은 0.16 의 의도
//! (락은 데이터, io 는 lock 시점 전달) 와도 맞지 않고 entry 까지 시그니처를 오염시킨다.
//!
//! 그래서 그런 trivial 임계구역에는 io 불필요한 atomic 스핀락을 쓴다. API 는
//! `std.Thread.Mutex` 와 동일(`lock`/`unlock`/`tryLock`)이라 *타입 선언만* 교체하면
//! 호출부는 그대로다.
//!
//! **주의**: 락 안에서 blocking I/O(fs/네트워크) 를 하거나 오래 잡거나 고경합인 곳에는
//! 쓰지 말 것 — 그건 `std.Io.Mutex` 가 맞다. 스핀락은 busy-wait 라 contention 시 코어를
//! 낭비한다.

const std = @import("std");

/// 짧은 임계구역용 io-free 배타 락. `std.Thread.Mutex` 대체 (동일 API).
pub const SpinLock = struct {
    state: u32 = 0,

    pub fn lock(self: *SpinLock) void {
        while (@cmpxchgWeak(u32, &self.state, 0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    /// non-blocking. 성공 시 true (락 보유), 실패 시 false.
    pub fn tryLock(self: *SpinLock) bool {
        return @cmpxchgStrong(u32, &self.state, 0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }
};

/// io-free reader/writer 스핀락. `std.Thread.RwLock` 대체 (동일 API:
/// lock/unlock = writer, lockShared/unlockShared = reader). reader 다수 동시 허용,
/// writer 배타. writer 기아 방지는 안 함 (캐시 short-section 용도라 충분).
///
/// state: 0=free, 음수가 아닌 N=reader N명, 0xFFFF_FFFF=writer 보유 sentinel.
pub const SpinRwLock = struct {
    /// 0 = free, 1..(WRITER-1) = reader count, WRITER = writer 보유.
    state: u32 = 0,

    const WRITER: u32 = 0xFFFF_FFFF;

    pub fn lock(self: *SpinRwLock) void {
        while (@cmpxchgWeak(u32, &self.state, 0, WRITER, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn tryLock(self: *SpinRwLock) bool {
        return @cmpxchgStrong(u32, &self.state, 0, WRITER, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinRwLock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }

    pub fn lockShared(self: *SpinRwLock) void {
        while (true) {
            const cur = @atomicLoad(u32, &self.state, .monotonic);
            // writer 보유 중이거나 reader 가 거의 가득(WRITER-1) 이면 대기.
            if (cur >= WRITER - 1) {
                std.atomic.spinLoopHint();
                continue;
            }
            if (@cmpxchgWeak(u32, &self.state, cur, cur + 1, .acquire, .monotonic) == null) return;
        }
    }

    pub fn tryLockShared(self: *SpinRwLock) bool {
        const cur = @atomicLoad(u32, &self.state, .monotonic);
        if (cur >= WRITER - 1) return false;
        return @cmpxchgStrong(u32, &self.state, cur, cur + 1, .acquire, .monotonic) == null;
    }

    pub fn unlockShared(self: *SpinRwLock) void {
        _ = @atomicRmw(u32, &self.state, .Sub, 1, .release);
    }
};

test "SpinLock: lock/tryLock/unlock" {
    var m: SpinLock = .{};
    m.lock();
    try std.testing.expect(!m.tryLock());
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

test "SpinRwLock: 다중 reader + 배타 writer" {
    var rw: SpinRwLock = .{};
    rw.lockShared();
    rw.lockShared();
    try std.testing.expect(!rw.tryLock()); // reader 있으면 writer 실패
    rw.unlockShared();
    rw.unlockShared();
    try std.testing.expect(rw.tryLock());
    try std.testing.expect(!rw.tryLockShared()); // writer 있으면 reader 실패
    rw.unlock();
}
