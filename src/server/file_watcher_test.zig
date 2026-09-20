const std = @import("std");
const FileWatcher = @import("file_watcher.zig").FileWatcher;

test "FileWatcher: init and deinit" {
    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());
}

test "FileWatcher: add and count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 임시 파일 생성
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test.txt", .data = "hello" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "test.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
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

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "a.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    watcher.removePath(path);
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());
}

test "FileWatcher: owns added path memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "owned.txt", .data = "owned" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "owned.txt", std.testing.allocator);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path);
    std.testing.allocator.free(path);

    const same_path = try tmp.dir.realPathFileAlloc(std.testing.io, "owned.txt", std.testing.allocator);
    defer std.testing.allocator.free(same_path);

    watcher.removePath(same_path);
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());
}

test "FileWatcher: clear paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.txt", .data = "x" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "y.txt", .data = "y" });
    const px = try tmp.dir.realPathFileAlloc(std.testing.io, "x.txt", std.testing.allocator);
    defer std.testing.allocator.free(px);
    const py = try tmp.dir.realPathFileAlloc(std.testing.io, "y.txt", std.testing.allocator);
    defer std.testing.allocator.free(py);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
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

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stable.txt", .data = "no change" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "stable.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path);

    // 짧은 timeout → 변경 없으면 빈 결과
    const changes = try watcher.waitForChanges(100);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "FileWatcher: detects file modification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "mod.txt", .data = "original" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "mod.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path);

    // 약간 대기 후 파일 수정 (다른 스레드에서)
    const write_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            // 50ms 대기 후 파일 수정
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.writeFile(io, .{ .sub_path = "mod.txt", .data = "modified content" }) catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });

    const changes = try watcher.waitForChanges(3000);
    write_thread.join();

    try std.testing.expect(changes.len > 0);
    try std.testing.expectEqual(.modified, changes[0].kind);
    try std.testing.expect(std.mem.endsWith(u8, changes[0].path, "mod.txt"));
}

test "FileWatcher: detects multiple file modifications" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "aaa" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "bbb" });
    const path_a = try tmp.dir.realPathFileAlloc(std.testing.io, "a.txt", std.testing.allocator);
    defer std.testing.allocator.free(path_a);
    const path_b = try tmp.dir.realPathFileAlloc(std.testing.io, "b.txt", std.testing.allocator);
    defer std.testing.allocator.free(path_b);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path_a);
    try watcher.addPath(path_b);

    // 별도 스레드에서 두 파일 동시 수정
    const write_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.writeFile(io, .{ .sub_path = "a.txt", .data = "aaa modified" }) catch {};
            dir.writeFile(io, .{ .sub_path = "b.txt", .data = "bbb modified" }) catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });

    // 첫 번째 waitForChanges로 최소 1개 이벤트 수집
    var total_changes: usize = 0;
    var found_a = false;
    var found_b = false;

    // kqueue는 한 번에 모두 반환할 수도, 따로 반환할 수도 있으므로 반복 수집
    for (0..5) |_| {
        const changes = try watcher.waitForChanges(500);
        for (changes) |change| {
            if (std.mem.endsWith(u8, change.path, "a.txt")) found_a = true;
            if (std.mem.endsWith(u8, change.path, "b.txt")) found_b = true;
        }
        total_changes += changes.len;
        if (found_a and found_b) break;
    }

    write_thread.join();

    try std.testing.expect(total_changes >= 2);
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

test "FileWatcher: detects file deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "del.txt", .data = "to be deleted" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "del.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path);

    const del_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.deleteFile(io, "del.txt") catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });

    const changes = try watcher.waitForChanges(3000);
    del_thread.join();

    try std.testing.expect(changes.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, changes[0].path, "del.txt"));
}

test "FileWatcher: removePath stops watching" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignore.txt", .data = "watch me" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "ignore.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(path);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    // 감시 해제
    watcher.removePath(path);
    try std.testing.expectEqual(@as(usize, 0), watcher.watchCount());

    // 감시 해제 후 파일 수정
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignore.txt", .data = "modified after remove" });

    // 짧은 timeout → 감시 해제했으므로 이벤트 없어야 함
    const changes = try watcher.waitForChanges(200);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "FileWatcher: add nonexistent path does not crash" {
    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    // 존재하지 않는 파일 → addPath는 에러 없이 skip
    try watcher.addPath("/nonexistent/path/file.txt");
    // kqueue backend: fd open 실패 시 skip하므로 count=0
    // mtime backend: stat 실패해도 등록하므로 count=1 가능
    // 어느 쪽이든 crash하면 안 됨
}

// issue #3858 — C2 epic PR-1 TDD failing test
// 디렉토리를 watch 하고 그 안에 새 file 이 생성되면 event 가 발생해야 한다.
// graph 외 .css 파일이 dev mode 중 생성될 때 native watcher 가 감지하는 인프라.
test "FileWatcher: watch directory — 새 파일 생성 시 event 발생 (#3858)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    // 디렉토리 자체를 watch
    try watcher.addPath(dir_path);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    // 별도 thread 가 50ms 후 디렉토리 안에 새 file 생성
    const create_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.writeFile(io, .{ .sub_path = "new.css", .data = ".x{}" }) catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });

    const changes = try watcher.waitForChanges(3000);
    create_thread.join();

    // 새 file 생성이 dir entry 변화 → 어떤 event 든 발생해야 함.
    // path 는 dir_path 자체 (kqueue) 또는 new.css 의 absolute path (inotify) 가능.
    try std.testing.expect(changes.len > 0);
}

// 같은 디렉토리에서 file 삭제 시도 event 발생.
test "FileWatcher: watch directory — file 삭제 시 event 발생 (#3858)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 디렉토리 watch 전에 file 미리 존재
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "victim.css", .data = ".v{}" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();

    try watcher.addPath(dir_path);

    const del_thread = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.deleteFile(io, "victim.css") catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });

    const changes = try watcher.waitForChanges(3000);
    del_thread.join();

    try std.testing.expect(changes.len > 0);
}

// #4682 — 에디터의 원자적 저장(임시파일에 쓰고 rename)은 파일을 **교체**한다.
//
// kqueue 는 경로가 아니라 열린 파일(inode)을 감시하므로, 교체되면 옛 fd 가 아무도 쓰지
// 않는 고아를 붙들게 된다. 예전에는 첫 교체에서 NOTE_DELETE 가 한 번 뜨고 **그 뒤로는
// 그 경로의 어떤 변경도 안 보였다** — dev 서버가 재시작 전까지 영구히 멎었다.
//
// 여기서는 **교체를 두 번** 한다. 첫 번째만 보는 테스트는 재등록이 없어도 통과하므로
// 결함을 못 잡는다. 두 번째 교체에서 이벤트가 오는지가 계약이다.
test "FileWatcher: 원자적 교체(rename) 후에도 계속 감시한다 (#4682)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "atomic.txt", .data = "v0" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "atomic.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();
    try watcher.addPath(path);

    const Replacer = struct {
        fn run(io: std.Io, dir: std.Io.Dir, tmp_name: []const u8, data: []const u8) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.writeFile(io, .{ .sub_path = tmp_name, .data = data }) catch return;
            dir.rename(tmp_name, dir, "atomic.txt", io) catch {};
        }
    };

    // 1회차 교체 — 재등록이 없어도 이벤트는 온다(옛 inode 의 DELETE).
    var t1 = try std.Thread.spawn(.{}, Replacer.run, .{ std.testing.io, tmp.dir, ".t1", "v1" });
    const first = watcher.waitForChanges(3000) catch |e| {
        t1.join();
        return e;
    };
    t1.join();
    try std.testing.expect(first.len > 0);

    // 2회차 교체 — 재등록이 됐을 때만 이벤트가 온다. 이게 회귀 방지의 본체다.
    var t2 = try std.Thread.spawn(.{}, Replacer.run, .{ std.testing.io, tmp.dir, ".t2", "v2" });
    const second = watcher.waitForChanges(3000) catch |e| {
        t2.join();
        return e;
    };
    t2.join();
    try std.testing.expect(second.len > 0);
    // 교체는 **수정**이다 — `.deleted` 로 분류되면 소비자가 outdir 에서 파일을 지운다.
    try std.testing.expect(second[0].kind == .modified);

    // 감시 대상 수는 그대로 — 교체는 경로를 늘리거나 줄이지 않는다.
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());
}

// #4682 적대적 검증 — 재등록이 **진짜 삭제를 수정으로 오인하면** 안 된다.
// `NOTE_DELETE` 를 받았을 때 같은 경로를 다시 열어 보는데, 파일이 정말 사라졌으면
// 열리지 않아야 하고 그때는 `.deleted` 로 보고해야 한다. 여기를 놓치면 삭제된 CSS 가
// outdir 에 영원히 남는다(#3858 의 reconcile 이 삭제를 못 본다).
test "FileWatcher: 진짜 삭제는 여전히 .deleted 로 보고 (#4682 회귀 가드)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gone.txt", .data = "bye" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "gone.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();
    try watcher.addPath(path);

    var th = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.deleteFile(io, "gone.txt") catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });

    const changes = try watcher.waitForChanges(3000);
    th.join();

    try std.testing.expect(changes.len > 0);
    var saw_deleted = false;
    for (changes) |c| {
        if (std.mem.eql(u8, c.path, path) and c.kind == .deleted) saw_deleted = true;
    }
    try std.testing.expect(saw_deleted);
}

// #4682 적대적 검증 — 삭제 후 **곧 재생성**되면 다시 감시하고, 그 사실을 알려야 한다.
//
// 삭제와 재생성 사이에는 파일이 없는 틈이 있다(에디터·스크립트·`git checkout`).
// 그 틈에 재등록을 시도하면 실패하는데, 거기서 포기하면 파일이 돌아와도 영영 안 보인다.
test "FileWatcher: 삭제 후 재생성되면 다시 감시한다 (#4682)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "revive.txt", .data = "v0" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "revive.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();
    try watcher.addPath(path);

    // 삭제 — 파일이 없는 동안이라 재등록은 실패한다.
    try tmp.dir.deleteFile(std.testing.io, "revive.txt");
    _ = try watcher.waitForChanges(300);

    // 되살린 뒤 폴 — 이 호출의 재시도가 감시를 다시 단다.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "revive.txt", .data = "v1" });
    _ = try watcher.waitForChanges(50);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    // 그리고 이후 수정도 계속 보여야 한다.
    var t2 = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.writeFile(io, .{ .sub_path = "revive.txt", .data = "v2" }) catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });
    const changes = watcher.waitForChanges(3000) catch |e| {
        t2.join();
        return e;
    };
    t2.join();
    try std.testing.expect(changes.len > 0);
}

// #4682 적대적 검증 — 파일이 **오래** 없다가 돌아와도 복구돼야 한다.
//
// 재시도 횟수에 상한을 뒀던 판(5회)에서는 1.5초쯤 비는 틈이 경계를 넘겨 복귀가 조용히
// 유실됐다. `git checkout`/브랜치 전환은 그 정도로 오래 비운다. 붙들고 있는 fd 를 바로
// 놓아주므로 오래 기다려도 새는 자원이 없다.
test "FileWatcher: 오래 비었다가 돌아온 파일도 다시 감시한다 (#4682)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "slow.txt", .data = "x" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "slow.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var watcher = try FileWatcher.init(std.testing.allocator, std.testing.io);
    defer watcher.deinit();
    try watcher.addPath(path);

    try tmp.dir.deleteFile(std.testing.io, "slow.txt");
    // 상한이 있었다면 여기서 이미 포기했을 만큼 많이 폴한다.
    var i: usize = 0;
    while (i < 20) : (i += 1) _ = try watcher.waitForChanges(5);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "slow.txt", .data = "back" });
    _ = try watcher.waitForChanges(50);
    try std.testing.expectEqual(@as(usize, 1), watcher.watchCount());

    // 재등록이 실제로 살아 있는지는 **이후 수정이 보이는지**로 확인한다.
    var t = try std.Thread.spawn(.{}, struct {
        fn run(io: std.Io, dir: std.Io.Dir) void {
            io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            dir.writeFile(io, .{ .sub_path = "slow.txt", .data = "again" }) catch {};
        }
    }.run, .{ std.testing.io, tmp.dir });
    const changes = watcher.waitForChanges(3000) catch |e| {
        t.join();
        return e;
    };
    t.join();
    try std.testing.expect(changes.len > 0);
}
