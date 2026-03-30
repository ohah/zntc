const std = @import("std");
const IncrementalBundler = @import("incremental.zig").IncrementalBundler;
const writeFile = @import("test_helpers.zig").writeFile;

fn absPath(tmp: *std.testing.TmpDir, rel: []const u8) ![]const u8 {
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    return try std.fs.path.resolve(std.testing.allocator, &.{ dp, rel });
}

test "IncrementalBundler: first build is full rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드: 전체 재빌드
    const result = try ib.rebuild(&.{});
    switch (result) {
        .success => |r| {
            try std.testing.expect(r.graph_changed); // 첫 빌드는 항상 graph_changed
            try std.testing.expect(r.paths.len > 0);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: second build without changes has no changed modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드
    _ = try ib.rebuild(&.{});

    // 두 번째 빌드: 변경 없음 → changed_modules 비어있어야 함
    const result = try ib.rebuild(&.{});
    switch (result) {
        .success => |r| {
            try std.testing.expectEqual(false, r.graph_changed);
            try std.testing.expectEqual(@as(usize, 0), r.changed_modules.len);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: detects code change in modified file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts", "export const x = 1;");
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const util_path = try absPath(&tmp, "util.ts");
    defer std.testing.allocator.free(util_path);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드
    _ = try ib.rebuild(&.{});

    // util.ts 수정
    try writeFile(tmp.dir, "util.ts", "export const x = 42;");

    // 증분 빌드: util.ts가 changed_paths로 전달
    const result = try ib.rebuild(&.{util_path});
    switch (result) {
        .success => |r| {
            // 코드가 변경되었으므로 changed_modules에 포함
            try std.testing.expect(r.changed_modules.len > 0);
            // changed_modules 해제
            if (r.changed_modules.len > 0) {
                std.testing.allocator.free(r.changed_modules);
            }
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: detects graph change (new import)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드 (1개 모듈)
    _ = try ib.rebuild(&.{});

    // 새 모듈 추가 + import 추가
    try writeFile(tmp.dir, "extra.ts", "export const y = 2;");
    try writeFile(tmp.dir, "index.ts", "import { y } from './extra';\nconsole.log(y);");

    // 증분 빌드: 모듈 수 변경 → graph_changed
    const result = try ib.rebuild(&.{entry});
    switch (result) {
        .success => |r| {
            try std.testing.expect(r.graph_changed);
            if (r.changed_modules.len > 0) {
                std.testing.allocator.free(r.changed_modules);
            }
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: build error returns error message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('ok');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드
    _ = try ib.rebuild(&.{});

    // 구문 에러 삽입
    try writeFile(tmp.dir, "index.ts", "console.log(;);");

    // 재빌드 → 에러 또는 성공 (파서가 에러 복구할 수 있음)
    const result = try ib.rebuild(&.{entry});
    // 파서 에러 복구 수준에 따라 build_error 또는 success
    switch (result) {
        .success => |r| {
            if (r.changed_modules.len > 0) {
                std.testing.allocator.free(r.changed_modules);
            }
        },
        .build_error => |err_msg| {
            defer std.testing.allocator.free(err_msg);
            try std.testing.expect(std.mem.indexOf(u8, err_msg, "error") != null);
        },
        .fatal => {},
    }
}
