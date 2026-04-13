//! 파일 워처 + 내용 해시 캐시를 묶은 상위 자료구조.
//!
//! `FileWatcher`는 OS 수준 변경만 알려준다 (kqueue/inotify/mtime). 저장·touch
//! 이벤트가 실제 내용 변경과 일치하지 않는 경우가 많아(atomic-write 후 재작성,
//! 에디터 touch 등), NAPI watch 모드는 파일별로 Wyhash-64 해시를 캐싱해서
//! "내용이 진짜 바뀐 파일"만 리빌드로 보낸다.
//!
//! 기존엔 napi_entry.zig에 `addAndCacheHash` 로컬 헬퍼 + 해시맵 수동 관리로
//! 흩어져 있었다. 이 모듈은 그 패턴을 캡슐화한다 (#1229 Part 2).

const std = @import("std");
const file_watcher = @import("file_watcher.zig");
const FileWatcher = file_watcher.FileWatcher;
const ChangeEvent = file_watcher.ChangeEvent;
const wyhash = @import("../util/wyhash.zig");

/// FileWatcher + path→content-hash 맵.
///
/// key 소유: `addPath` 시 경로 문자열을 dupe해서 해시맵 키로 가진다.
/// FileWatcher도 내부적으로 dupe하므로 두 쪽이 별도 복사본을 소유한다 —
/// `removePath`에서 맞춰 해제한다.
pub const TrackedFileSet = struct {
    allocator: std.mem.Allocator,
    watcher: FileWatcher,
    hashes: std.StringHashMap(u64),
    max_bytes: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) !Self {
        return .{
            .allocator = allocator,
            .watcher = try FileWatcher.init(allocator),
            .hashes = std.StringHashMap(u64).init(allocator),
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Self) void {
        self.watcher.deinit();
        var it = self.hashes.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.hashes.deinit();
    }

    /// 감시 대상 등록 + 해시 캐시 갱신.
    /// `overwrite=false`면 기존 해시를 보존한다 (증분 재-싱크 용도).
    /// 반환값: watcher 등록 성공 여부.
    pub fn addPath(self: *Self, path: []const u8, overwrite: bool) bool {
        self.watcher.addPath(path) catch return false;
        if (!overwrite and self.hashes.contains(path)) return true;
        const h = wyhash.hashFileStreaming(path, self.max_bytes) orelse 0;
        if (self.hashes.getEntry(path)) |e| {
            e.value_ptr.* = h;
        } else {
            const key = self.allocator.dupe(u8, path) catch return true;
            self.hashes.put(key, h) catch self.allocator.free(key);
        }
        return true;
    }

    /// 워처 + 해시 캐시 양쪽에서 제거.
    pub fn removePath(self: *Self, path: []const u8) void {
        self.watcher.removePath(path);
        if (self.hashes.fetchRemove(path)) |kv| self.allocator.free(kv.key);
    }

    pub fn contains(self: *const Self, path: []const u8) bool {
        return self.hashes.contains(path);
    }

    pub fn keyIterator(self: *Self) std.StringHashMap(u64).KeyIterator {
        return self.hashes.keyIterator();
    }

    /// 파일의 현재 내용 해시를 캐시와 비교. 내용이 바뀌었으면 캐시 갱신 후 true.
    /// 읽기 실패/크기 초과 시 false.
    pub fn markIfChanged(self: *Self, path: []const u8) bool {
        const new_hash = wyhash.hashFileStreaming(path, self.max_bytes) orelse return false;
        const old_hash = self.hashes.get(path);
        if (old_hash != null and old_hash.? == new_hash) return false;
        if (self.hashes.getEntry(path)) |entry| {
            entry.value_ptr.* = new_hash;
        } else {
            const key_copy = self.allocator.dupe(u8, path) catch return false;
            self.hashes.put(key_copy, new_hash) catch {
                self.allocator.free(key_copy);
                return false;
            };
        }
        return true;
    }

    pub fn watchCount(self: *const Self) usize {
        return self.watcher.watchCount();
    }

    pub fn waitForChanges(self: *Self, timeout_ms: u32) ![]const ChangeEvent {
        return self.watcher.waitForChanges(timeout_ms);
    }
};

// ─── 테스트 ───

const testing = std.testing;

test "addPath registers watcher + caches hash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hello" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.txt");
    defer testing.allocator.free(path);

    var set = try TrackedFileSet.init(testing.allocator, 1024 * 1024);
    defer set.deinit();

    try testing.expect(set.addPath(path, true));
    try testing.expect(set.contains(path));
    try testing.expectEqual(@as(usize, 1), set.watchCount());
}

test "markIfChanged detects content change, same content returns false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "v1" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.txt");
    defer testing.allocator.free(path);

    var set = try TrackedFileSet.init(testing.allocator, 1024 * 1024);
    defer set.deinit();

    _ = set.addPath(path, true);
    try testing.expect(!set.markIfChanged(path)); // 같은 내용

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "v2-different" });
    try testing.expect(set.markIfChanged(path)); // 바뀜
    try testing.expect(!set.markIfChanged(path)); // 캐시 갱신됨
}

test "overwrite=false preserves existing hash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "v1" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.txt");
    defer testing.allocator.free(path);

    var set = try TrackedFileSet.init(testing.allocator, 1024 * 1024);
    defer set.deinit();

    _ = set.addPath(path, true);
    const h1 = set.hashes.get(path).?;

    // 파일 내용 변경, overwrite=false — 캐시된 해시가 유지되어야 함 (재-싱크 시맨틱)
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "v2" });
    _ = set.addPath(path, false);
    try testing.expectEqual(h1, set.hashes.get(path).?);
}

test "removePath clears from both watcher and hash cache" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "x" });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "a.txt");
    defer testing.allocator.free(path);

    var set = try TrackedFileSet.init(testing.allocator, 1024 * 1024);
    defer set.deinit();

    _ = set.addPath(path, true);
    set.removePath(path);
    try testing.expect(!set.contains(path));
}
