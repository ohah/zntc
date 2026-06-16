//! 공용 유틸리티 모음.

pub const wyhash = @import("wyhash.zig");
pub const codec_io = @import("codec_io.zig");
pub const string_list = @import("string_list.zig");
pub const spin_lock = @import("spin_lock.zig");
pub const SpinLock = spin_lock.SpinLock;
pub const SpinRwLock = spin_lock.SpinRwLock;

/// 병렬 dispatch 청크 크기 계산 (#4007). `total` 개 작업을 ~`parallelism`*4 청크로 나눌 때
/// 청크당 작업 수(ceil). target_chunks 를 `total` 로 캡해 oversubscribe 방지 + `total / target
/// + remainder` 형태로 계산해 32-bit usize 에서 `total + target - 1` 류 오버플로를 회피한다
/// (`parallelism` 이 --jobs 로 비정상적으로 커도 안전 — 캡 후 chunk=1 로 degrade).
pub fn chunkSize(total: usize, parallelism: usize) usize {
    if (total == 0) return 1;
    const target_chunks = @max(@as(usize, 1), @min(total, parallelism *| 4));
    const base = total / target_chunks;
    return if (total % target_chunks != 0) base + 1 else base;
}

test chunkSize {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), chunkSize(0, 8)); // 빈 입력 → 1 (무한루프 방지)
    try std.testing.expectEqual(@as(usize, 1), chunkSize(1, 8));
    try std.testing.expectEqual(@as(usize, 1), chunkSize(5, 8)); // total < parallelism*4 → 청크당 1
    try std.testing.expectEqual(@as(usize, 16), chunkSize(500, 8)); // ceil(500/32)
    try std.testing.expectEqual(@as(usize, 63), chunkSize(2000, 8)); // ceil(2000/32)
    try std.testing.expectEqual(@as(usize, 1), chunkSize(100, std.math.maxInt(usize))); // 비정상 parallelism → 오버플로 없이 chunk=1
}
