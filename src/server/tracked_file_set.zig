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
    /// issue #3858 — dir 자체를 watch 대상으로 등록한 path 들. addDirPath 가 set.
    /// caller (watchWorkerThread) 가 isDirPath 로 event dispatch 분기.
    dir_paths: std.StringHashMap(void),
    max_bytes: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) !Self {
        return .{
            .allocator = allocator,
            .watcher = try FileWatcher.init(allocator),
            .hashes = std.StringHashMap(u64).init(allocator),
            .dir_paths = std.StringHashMap(void).init(allocator),
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Self) void {
        self.watcher.deinit();
        var it = self.hashes.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.hashes.deinit();
        var dit = self.dir_paths.keyIterator();
        while (dit.next()) |k| self.allocator.free(k.*);
        self.dir_paths.deinit();
    }

    /// 감시 대상 등록 + 해시 캐시 갱신.
    /// `overwrite=false`면 기존 해시를 보존한다 (증분 재-싱크 용도).
    /// 반환값: watcher 등록 성공 여부.
    pub fn addPath(self: *Self, path: []const u8, overwrite: bool) bool {
        self.watcher.addPath(path) catch return false;
        const gop = self.hashes.getOrPut(path) catch return true;
        if (gop.found_existing) {
            if (!overwrite) return true;
        } else {
            const key = self.allocator.dupe(u8, path) catch {
                _ = self.hashes.remove(path);
                return true;
            };
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = wyhash.hashFileStreaming(path, self.max_bytes) orelse 0;
        return true;
    }

    /// issue #3858 — dir 자체를 감시 대상으로 등록. file 과 다른 점:
    /// (a) hash 비교 우회 (dir 의 content hash 의미 없음, markIfChanged 시 dir_paths 면 항상 true)
    /// (b) waitForChanges 가 dir entry 변화 시 dir path 의 ChangeEvent emit (PR-1 의 dir-watch)
    /// caller (watchWorkerThread) 가 dir event 시 rescan + 신규 file 의 addPath 수행.
    /// 반환값: watcher 등록 성공 여부.
    pub fn addDirPath(self: *Self, path: []const u8) bool {
        self.watcher.addPath(path) catch return false;
        if (self.dir_paths.contains(path)) return true;
        const key = self.allocator.dupe(u8, path) catch return true;
        self.dir_paths.put(key, {}) catch {
            self.allocator.free(key);
            return true;
        };
        return true;
    }

    /// issue #3858 — path 가 dir-path 로 등록됐는지. caller 가 event 의 path
    /// 가 dir 인지 file 인지 dispatch 분기에 사용.
    pub fn isDirPath(self: *const Self, path: []const u8) bool {
        return self.dir_paths.contains(path);
    }

    /// issue #3858 — rescan 후 발견된 신규 file 등록. watcher.addPath + hashes
    /// 에 dummy hash(0) 등록 (key 는 dupe). 이렇게 하면:
    /// (a) markIfChanged 의 첫 호출이 실 hash 와 0 비교 → 다르면 true → changed_files
    ///     에 들어가 첫 emit 정상 작동
    /// (b) keyIterator 가 path 를 iterate — 이후 delete detect 시 to_remove 에
    ///     정상 추가됨 (이전엔 hashes 미등록이라 iterate 안 되어 누락)
    /// 반환값: watcher 등록 성공 여부.
    pub fn addWatcherOnly(self: *Self, path: []const u8) bool {
        self.watcher.addPath(path) catch return false;
        const gop = self.hashes.getOrPut(path) catch return true;
        if (!gop.found_existing) {
            const key = self.allocator.dupe(u8, path) catch {
                _ = self.hashes.remove(path);
                return true;
            };
            gop.key_ptr.* = key;
            gop.value_ptr.* = 0; // dummy — markIfChanged 의 첫 호출이 실 hash 로 갱신 + true 반환
        }
        return true;
    }

    /// 워처 + 해시 캐시 양쪽에서 제거.
    pub fn removePath(self: *Self, path: []const u8) void {
        self.watcher.removePath(path);
        if (self.hashes.fetchRemove(path)) |kv| self.allocator.free(kv.key);
        if (self.dir_paths.fetchRemove(path)) |kv| self.allocator.free(kv.key);
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
        const gop = self.hashes.getOrPut(path) catch return false;
        if (gop.found_existing) {
            if (gop.value_ptr.* == new_hash) return false;
        } else {
            const key = self.allocator.dupe(u8, path) catch {
                _ = self.hashes.remove(path);
                return false;
            };
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = new_hash;
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
