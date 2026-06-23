// disk_cache_test.zig — #4438 디스크 캐시 IO 레이어 put/get round-trip + miss + overwrite.
//
// std.testing.tmpDir 로 격리된 임시 디렉토리를 캐시 root 로 쓴다.

const std = @import("std");
const testing = std.testing;
const DiskCache = @import("disk_cache.zig").DiskCache;

const KEY_A: u64 = 0xABCDEF0123456789;
const KEY_B: u64 = 0x00000000000000FF; // shard "00", 작은 값(0 패딩 확인)
const MAX: usize = 1 << 20;

fn openCache(tmp: *std.testing.TmpDir) !DiskCache {
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    return DiskCache.init(testing.allocator, root);
}

test "disk_cache: put/get round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try openCache(&tmp);
    defer cache.deinit();

    try cache.put(testing.io, KEY_A, "hello disk cache");

    const got = (try cache.get(testing.io, testing.allocator, KEY_A, MAX)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello disk cache", got);
}

test "disk_cache: miss 는 null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try openCache(&tmp);
    defer cache.deinit();

    try testing.expect((try cache.get(testing.io, testing.allocator, KEY_A, MAX)) == null);

    // 다른 key 만 채우고 조회 — 여전히 miss.
    try cache.put(testing.io, KEY_B, "x");
    try testing.expect((try cache.get(testing.io, testing.allocator, KEY_A, MAX)) == null);
}

test "disk_cache: overwrite 는 atomic 교체" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try openCache(&tmp);
    defer cache.deinit();

    try cache.put(testing.io, KEY_A, "first version AAAA");
    try cache.put(testing.io, KEY_A, "second longer version BBBBBBBB");

    const got = (try cache.get(testing.io, testing.allocator, KEY_A, MAX)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("second longer version BBBBBBBB", got);
}

test "disk_cache: 빈 데이터 + 작은-key 샤딩" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try openCache(&tmp);
    defer cache.deinit();

    try cache.put(testing.io, KEY_B, ""); // 빈 바이트 경계
    const got = (try cache.get(testing.io, testing.allocator, KEY_B, MAX)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "disk_cache: max_bytes 초과는 miss (fail-open)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try openCache(&tmp);
    defer cache.deinit();

    try cache.put(testing.io, KEY_A, "0123456789"); // 10 바이트
    // 상한 4 바이트로 읽으면 StreamTooLong → hard error 가 아니라 miss(null).
    try testing.expect((try cache.get(testing.io, testing.allocator, KEY_A, 4)) == null);
    // 충분한 상한이면 정상.
    const got = (try cache.get(testing.io, testing.allocator, KEY_A, MAX)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("0123456789", got);
}

test "disk_cache: 동시 put (seq 유일성 + 같은-샤드 createDirPath race)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 여러 스레드가 한 인스턴스를 공유 → thread-safe allocator 필요(경로 문자열 할당).
    // smp_allocator 는 전역 thread-safe; leak 감지는 다른 테스트(testing.allocator)가 커버.
    const alloc = std.heap.smp_allocator;
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);
    var cache = try DiskCache.init(alloc, root);
    defer cache.deinit();

    const N = 16;
    const Worker = struct {
        // key 0..15 는 hex 앞 2자리가 전부 "00" → 같은 샤드에 동시 createDirPath(멱등성 검증).
        fn run(c: *const DiskCache, k: u64) void {
            var buf: [24]u8 = undefined;
            const data = std.fmt.bufPrint(&buf, "payload-{d}", .{k}) catch return;
            c.put(testing.io, k, data) catch {};
        }
    };
    var threads: [N]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &cache, @as(u64, i) });
    for (&threads) |t| t.join();

    // 전부 성공·독립 보관됐는지(put 실패 시 get 이 null → .? 패닉으로 드러남).
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const got = (try cache.get(testing.io, alloc, i, MAX)).?;
        defer alloc.free(got);
        var buf: [24]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "payload-{d}", .{i});
        try testing.expectEqualStrings(want, got);
    }
}

test "disk_cache: 여러 key 독립 보관" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cache = try openCache(&tmp);
    defer cache.deinit();

    var k: u64 = 0;
    while (k < 8) : (k += 1) {
        var buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "payload-{d}", .{k});
        try cache.put(testing.io, k *% 0x9E3779B97F4A7C15, data);
    }
    k = 0;
    while (k < 8) : (k += 1) {
        const got = (try cache.get(testing.io, testing.allocator, k *% 0x9E3779B97F4A7C15, MAX)).?;
        defer testing.allocator.free(got);
        var buf: [16]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "payload-{d}", .{k});
        try testing.expectEqualStrings(want, got);
    }
}

test "disk_cache: initVersioned 가 옛 build_id dir GC + 사용자 dir 보존 (#4438)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const BID_OLD: u64 = 0x1111111111111111;
    const BID_NEW: u64 = 0x2222222222222222;

    // 옛 버전 캐시 채움 → <root>/1111.../<shard>/ 생성(put 이 dir lazy 생성).
    {
        var old = try DiskCache.initVersioned(testing.allocator, testing.io, root, BID_OLD);
        defer old.deinit();
        try old.put(testing.io, KEY_A, "old-version-entry");
    }
    // 비-hex 사용자 디렉토리(GC 가 건드리면 안 됨).
    try tmp.dir.createDirPath(testing.io, "user-data");

    // 새 버전 init → prune 이 옛 16-hex dir 삭제 후 새 dir 사용.
    {
        var new = try DiskCache.initVersioned(testing.allocator, testing.io, root, BID_NEW);
        defer new.deinit();
        try new.put(testing.io, KEY_A, "new-version-entry");
        const got = (try new.get(testing.io, testing.allocator, KEY_A, MAX)).?;
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("new-version-entry", got); // 새 버전은 정상 read
    }

    var old_hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&old_hex, "{x:0>16}", .{BID_OLD}) catch unreachable;
    // 옛 build_id dir 은 GC 됨(access 성공하면 미삭제 = 실패).
    if (tmp.dir.access(testing.io, &old_hex, .{})) |_| {
        return error.OldVersionDirNotPruned;
    } else |_| {}
    // 사용자 dir(비-hex)·새 build_id dir 은 보존.
    try tmp.dir.access(testing.io, "user-data", .{});
    var new_hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&new_hex, "{x:0>16}", .{BID_NEW}) catch unreachable;
    try tmp.dir.access(testing.io, &new_hex, .{});
}
