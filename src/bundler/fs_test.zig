//! src/bundler/fs.zig 단위 테스트.
//!
//! RealFS 의 호스트 fs 통합만 검증 (VirtualFS 는 Phase 2 PR 6 에서).
//! 임시 디렉토리 (std.testing.tmpDir) 를 사용해 격리.

const std = @import("std");
const testing = std.testing;
const fs = @import("fs.zig");

test "RealFS.readFile — 정상 케이스" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello world" });

    var sub_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try tmp.dir.realpath("hello.txt", &sub_path_buf);

    const real = fs.RealFS.init();
    const loaded = try real.readFile(testing.allocator, abs_path, 1024);
    defer testing.allocator.free(loaded.contents);

    try testing.expectEqualStrings("hello world", loaded.contents);
    try testing.expectEqual(fs.Namespace.file, loaded.namespace);
    try testing.expectEqual(@import("types.zig").ModuleType.unknown, loaded.module_type);
}

test "RealFS.readFile — 존재하지 않는 파일은 NotFound" {
    const real = fs.RealFS.init();
    const result = real.readFile(testing.allocator, "/zts/no_such_path/abcdef", 1024);
    try testing.expectError(fs.FsError.NotFound, result);
}

test "RealFS.access — 존재하면 void, 없으면 NotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "exists.txt", .data = "" });

    var sub_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_path = try tmp.dir.realpath("exists.txt", &sub_path_buf);

    const real = fs.RealFS.init();
    try real.access(abs_path);
    try testing.expectError(fs.FsError.NotFound, real.access("/zts/no_such_path/abcdef"));
}

test "RealFS.statFile — file kind + size 정확" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "size.txt", .data = "12345" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try tmp.dir.realpath("size.txt", &buf);

    const real = fs.RealFS.init();
    const stat = try real.statFile(file_path);
    try testing.expectEqual(@as(u64, 5), stat.size);
    try testing.expect(!stat.is_dir);
    try testing.expectEqual(fs.EntryKind.file, stat.kind);
}

test "RealFS.statFile — directory kind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("a_dir");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath("a_dir", &buf);

    const real = fs.RealFS.init();
    const stat = try real.statFile(dir_path);
    try testing.expect(stat.is_dir);
    try testing.expectEqual(fs.EntryKind.directory, stat.kind);
}

test "RealFS.statFile — symlink-to-file 은 kind=.file (symlink 따라감)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "target.txt", .data = "x" });
    tmp.dir.symLink("target.txt", "link.txt", .{}) catch |err| switch (err) {
        // Windows 등 symlink 권한 부족 환경 skip
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try tmp.dir.realpath("link.txt", &buf);

    const real = fs.RealFS.init();
    const stat = try real.statFile(link_path);
    // statFile (vs lstat) 은 symlink 를 따라가서 target 의 kind 반환 — resolver.fileExists 의
    // node_modules 에 있는 bun/pnpm symlink 동작과 일치.
    try testing.expectEqual(fs.EntryKind.file, stat.kind);
}

test "RealFS.statFile — symlink-to-directory 는 kind=.directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("target_dir");
    tmp.dir.symLink("target_dir", "link_dir", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try tmp.dir.realpath("link_dir", &buf);

    const real = fs.RealFS.init();
    const stat = try real.statFile(link_path);
    try testing.expectEqual(fs.EntryKind.directory, stat.kind);
    try testing.expect(stat.is_dir);
}

test "RealFS.listDir — 항목 수집 + free" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "" });
    try tmp.dir.makeDir("subdir");

    var sub_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &sub_path_buf);

    const real = fs.RealFS.init();
    const entries = try real.listDir(testing.allocator, dir_path);
    defer {
        for (entries) |e| testing.allocator.free(e.name);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 3), entries.len);

    var saw_a = false;
    var saw_b = false;
    var saw_subdir = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "a.txt")) {
            saw_a = true;
            try testing.expectEqual(fs.EntryKind.file, e.kind);
        } else if (std.mem.eql(u8, e.name, "b.txt")) {
            saw_b = true;
        } else if (std.mem.eql(u8, e.name, "subdir")) {
            saw_subdir = true;
            try testing.expectEqual(fs.EntryKind.directory, e.kind);
        }
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
    try testing.expect(saw_subdir);
}

test "RealFS.listDir — 존재하지 않는 디렉토리는 NotFound" {
    const real = fs.RealFS.init();
    const result = real.listDir(testing.allocator, "/zts/no_such_dir/abcdef");
    try testing.expectError(fs.FsError.NotFound, result);
}

test "RealFS.listDir — symlink 은 kind=.symlink (target 따라가지 않음, lstat)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "real.txt", .data = "" });
    tmp.dir.symLink("real.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &buf);

    const real = fs.RealFS.init();
    const entries = try real.listDir(testing.allocator, dir_path);
    defer {
        for (entries) |e| testing.allocator.free(e.name);
        testing.allocator.free(entries);
    }

    var saw_symlink = false;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "link.txt")) {
            saw_symlink = true;
            // resolver 의 readdir 캐시가 symlink 를 file/dir 양쪽에 등록하는 동작에 필수.
            try testing.expectEqual(fs.EntryKind.symlink, e.kind);
        }
    }
    try testing.expect(saw_symlink);
}

test "RealFS.realpath — symlink 정규화" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "real.txt", .data = "x" });
    tmp.dir.symLink("real.txt", "link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = try tmp.dir.realpath("link.txt", &buf);

    const real = fs.RealFS.init();
    const resolved = try real.realpath(testing.allocator, link_path);
    defer testing.allocator.free(resolved);

    // realpath 결과는 link 가 아닌 target (real.txt) 의 정규화 경로
    try testing.expect(std.mem.endsWith(u8, resolved, "real.txt"));
}

test "RealFS.realpath — 존재하지 않는 path 는 NotFound" {
    const real = fs.RealFS.init();
    const result = real.realpath(testing.allocator, "/zts/no_such_path/xyz");
    try testing.expectError(fs.FsError.NotFound, result);
}

test "Implementation 은 native 빌드에서 RealFS" {
    if (@import("builtin").target.cpu.arch == .wasm32) return error.SkipZigTest;
    try testing.expect(fs.Implementation == fs.RealFS);
}

test "LoadedModule default 값" {
    const m: fs.LoadedModule = .{
        .contents = "x",
        .path = "y",
    };
    try testing.expectEqual(fs.Namespace.file, m.namespace);
    try testing.expectEqual(@import("types.zig").ModuleType.unknown, m.module_type);
}
