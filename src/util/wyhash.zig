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
/// `max_bytes` 초과 시 size+mtime 기반 pseudo-hash로 폴백 (RN 등 vendor 번들/locale JSON 대응 — #1233).
/// 열기/stat/읽기 실패 시 null.
pub fn hashFileStreaming(path: []const u8, max_bytes: usize) ?u64 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > max_bytes) {
        // 거대 파일: 내용 스트리밍 비용을 피하고 size+mtime으로 pseudo-hash.
        // mtime만 갱신될 때 false-positive가 생길 수 있지만 stale output보다 안전.
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&stat.size));
        h.update(std.mem.asBytes(&stat.mtime));
        return h.final();
    }
    var hasher = std.hash.Wyhash.init(0);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch return null;
        if (n == 0) break;
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

test "hashFileStreaming over-limit falls back to size+mtime pseudo-hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "big.txt", .data = "0123456789" });
    const real = try tmp.dir.realpathAlloc(std.testing.allocator, "big.txt");
    defer std.testing.allocator.free(real);
    // 한도 초과 — null 대신 pseudo-hash 반환 (size+mtime).
    const fallback = hashFileStreaming(real, 5) orelse return error.HashFailed;
    const full = hashFileStreaming(real, 100) orelse return error.HashFailed;
    // 둘은 다른 알고리즘이므로 서로 달라야 함 (확률적 — 충돌 매우 희박).
    try std.testing.expect(fallback != full);
}

test "hashFileStreaming missing file returns null" {
    try std.testing.expect(hashFileStreaming("/nonexistent/zts_wyhash_test.txt", 1024) == null);
}
