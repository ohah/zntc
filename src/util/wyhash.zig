//! Wyhash 공통 헬퍼.
//!
//! `std.hash.Wyhash`의 반복 패턴을 한 곳에 모은다 — 64-bit one-shot,
//! 8자리 hex 요약(content hash placeholder), 파일 스트리밍 해시.
//! 스트리밍 스킵 해싱(`bundler/emitter/chunks.zig`)처럼 특수한 경우는
//! 여기에 넣지 않는다.

const std = @import("std");

/// 64-bit Wyhash one-shot.
pub fn hashU64(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

/// 하위 32-bit 절삭 후 16진수 8자리 (content hash placeholder).
pub fn hashHex8(data: []const u8) [8]u8 {
    const hash_val = std.hash.Wyhash.hash(0, data);
    var buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>8}", .{@as(u32, @truncate(hash_val))}) catch unreachable;
    return buf;
}

/// 파일 내용의 Wyhash-64. 파일을 64KB 버퍼로 순회하여 대용량에서도 메모리 부담 없음.
/// `max_bytes` 초과 시 null. 열기/읽기 실패 시 null.
pub fn hashFileStreaming(path: []const u8, max_bytes: usize) ?u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    var hasher = std.hash.Wyhash.init(0);
    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = file.read(&buf) catch return null;
        if (n == 0) break;
        total += n;
        if (total > max_bytes) return null;
        hasher.update(buf[0..n]);
    }
    return hasher.final();
}

// ─── 테스트 ───

test "hashU64 deterministic" {
    try std.testing.expectEqual(hashU64("hello"), hashU64("hello"));
    try std.testing.expect(hashU64("hello") != hashU64("hellp"));
}

test "hashHex8 format" {
    const out = hashHex8("abc");
    try std.testing.expectEqual(@as(usize, 8), out.len);
    for (out) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // low 32-bit와 일치하는지 확인
    const expect_u32 = @as(u32, @truncate(hashU64("abc")));
    var expect_buf: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&expect_buf, "{x:0>8}", .{expect_u32}) catch unreachable;
    try std.testing.expectEqualSlices(u8, &expect_buf, &out);
}

test "hashFileStreaming matches hashU64" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const contents = "hello world, wyhash streaming";
    try tmp.dir.writeFile(.{ .sub_path = "t.txt", .data = contents });
    const real = try tmp.dir.realpathAlloc(std.testing.allocator, "t.txt");
    defer std.testing.allocator.free(real);
    const got = hashFileStreaming(real, 1024 * 1024) orelse return error.HashFailed;
    try std.testing.expectEqual(hashU64(contents), got);
}

test "hashFileStreaming respects max_bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "big.txt", .data = "0123456789" });
    const real = try tmp.dir.realpathAlloc(std.testing.allocator, "big.txt");
    defer std.testing.allocator.free(real);
    try std.testing.expect(hashFileStreaming(real, 5) == null);
    try std.testing.expect(hashFileStreaming(real, 100) != null);
}

test "hashFileStreaming missing file returns null" {
    try std.testing.expect(hashFileStreaming("/nonexistent/zts_wyhash_test.txt", 1024) == null);
}
