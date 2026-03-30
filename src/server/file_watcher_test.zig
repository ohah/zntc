const std = @import("std");
const FileWatcher = @import("file_watcher.zig").FileWatcher;

test "FileWatcher: init and deinit" {
    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());
}

test "FileWatcher: add and count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 임시 파일 생성
    try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = "hello" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "test.txt");
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    try watcher.addPath(path);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    // 중복 추가 → 카운트 불변
    try watcher.addPath(path);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());
}

test "FileWatcher: remove path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "a" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "a.txt");
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    try watcher.addPath(path);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    watcher.removePath(path);
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());
}

test "FileWatcher: clear paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "x.txt", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "y.txt", .data = "y" });
    const px = try tmp.dir.realpathAlloc(std.testing.allocator, "x.txt");
    defer std.testing.allocator.free(px);
    const py = try tmp.dir.realpathAlloc(std.testing.allocator, "y.txt");
    defer std.testing.allocator.free(py);

    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    try watcher.addPath(px);
    try watcher.addPath(py);
    try std.testing.expectEqual(@as(usize, 2), watcher.watchCount());

    watcher.clearPaths();
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());
}

test "FileWatcher: timeout returns empty when no changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "stable.txt", .data = "no change" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "stable.txt");
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    try watcher.addPath(path);

    // 짧은 timeout → 변경 없으면 빈 결과
    const changes = try watcher.waitForChanges(100);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "FileWatcher: detects file modification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "mod.txt", .data = "original" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "mod.txt");
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    try watcher.addPath(path);

    // 약간 대기 후 파일 수정 (다른 스레드에서)
    const write_thread = try std.Thread.spawn(.{}, struct {
        fn run(dir: std.fs.Dir) void {
            // 50ms 대기 후 파일 수정
            std.Thread.sleep(50 * std.time.ns_per_ms);
            dir.writeFile(.{ .sub_path = "mod.txt", .data = "modified content" }) catch {};
        }
    }.run, .{tmp.dir});

    const changes = try watcher.waitForChanges(3000);
    write_thread.join();

    try std.testing.expect(changes.len > 0);
    try std.testing.expectEqual(.modified, changes[0].kind);
    try std.testing.expect(std.mem.endsWith(u8, changes[0].path, "mod.txt"));
}

test "FileWatcher: add nonexistent path does not crash" {
    var watcher = try FileWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    // 존재하지 않는 파일 → addPath는 에러 없이 skip
    try watcher.addPath("/nonexistent/path/file.txt");
    // kqueue backend: fd open 실패 시 skip하므로 count=0
    // mtime backend: stat 실패해도 등록하므로 count=1 가능
    // 어느 쪽이든 crash하면 안 됨
}
