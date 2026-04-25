const std = @import("std");
const resolve_cache = @import("resolve_cache.zig");
const ResolveCache = resolve_cache.ResolveCache;
const matchGlob = resolve_cache.matchGlob;
const isNodeBuiltin = resolve_cache.isNodeBuiltin;
const profile = @import("../profile.zig");
const ResolvedModule = @import("plugin.zig").ResolvedModule;

// ============================================================
// Tests
// ============================================================

test "matchGlob: exact match" {
    try std.testing.expect(matchGlob("react", "react"));
    try std.testing.expect(!matchGlob("react", "react-dom"));
}

test "matchGlob: wildcard" {
    try std.testing.expect(matchGlob("@mui/*", "@mui/material"));
    try std.testing.expect(matchGlob("@mui/*", "@mui/icons"));
    // * 는 / 를 매칭하지 않음
    try std.testing.expect(!matchGlob("@mui/*", "@mui/icons/filled"));
}

test "matchGlob: node: prefix" {
    try std.testing.expect(matchGlob("node:*", "node:fs"));
    try std.testing.expect(matchGlob("node:*", "node:path"));
    try std.testing.expect(!matchGlob("node:*", "node:fs/promises"));
}

test "isExternal: node: prefix always external" {
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("node:fs"));
    try std.testing.expect(cache.isExternal("node:path"));
    try std.testing.expect(!cache.isExternal("react"));
}

test "isExternal: node builtins when platform=node" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("fs"));
    try std.testing.expect(cache.isExternal("path"));
    try std.testing.expect(cache.isExternal("crypto"));
    try std.testing.expect(!cache.isExternal("react"));
}

test "isNodeBuiltin" {
    try std.testing.expect(isNodeBuiltin("util"));
    try std.testing.expect(isNodeBuiltin("fs"));
    try std.testing.expect(isNodeBuiltin("path"));
    try std.testing.expect(isNodeBuiltin("node:fs"));
    try std.testing.expect(isNodeBuiltin("node:util"));
    try std.testing.expect(isNodeBuiltin("util/types"));
    try std.testing.expect(isNodeBuiltin("fs/promises"));
    try std.testing.expect(!isNodeBuiltin("react"));
    try std.testing.expect(!isNodeBuiltin("lodash"));
    try std.testing.expect(!isNodeBuiltin("@babel/core"));
}

test "isExternal: node builtins NOT external when platform=browser" {
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    try std.testing.expect(!cache.isExternal("fs"));
    try std.testing.expect(!cache.isExternal("path"));
}

test "isExternal: user patterns" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{ "react", "@mui/*" } });
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("react"));
    try std.testing.expect(cache.isExternal("@mui/material"));
    try std.testing.expect(!cache.isExternal("vue"));
}

test "resolve: external returns null" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    const result = try cache.resolve("/some/dir", "react", .static_import);
    try std.testing.expect(result == null);
}

test "resolve: cache hit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    // 파일 생성
    const file = try tmp.dir.createFile("foo.ts", .{});
    file.close();

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    // 첫 번째 호출 (캐시 미스) — caller 소유
    const result1 = (try cache.resolve(dir_path, "./foo", .static_import)).?;
    defer freeResolvedPath(result1);
    const path1 = switch (result1) {
        .file => |f| f.path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.endsWith(u8, path1, "foo.ts"));

    // 두 번째 호출 (캐시 히트) — 별도 할당, caller 소유
    const result2 = (try cache.resolve(dir_path, "./foo", .static_import)).?;
    defer freeResolvedPath(result2);
    const path2 = switch (result2) {
        .file => |f| f.path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.endsWith(u8, path2, "foo.ts"));

    // 내용은 같지만 포인터는 다름 (각각 독립 할당)
    try std.testing.expectEqualStrings(path1, path2);
    try std.testing.expect(path1.ptr != path2.ptr);
}

test "resolve: not found cached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    // 존재하지 않는 파일
    const r1 = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r1);

    // 두 번째 호출도 ModuleNotFound (캐시에서)
    const r2 = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r2);
}

test "resolve: profile .resolve 활성 시 누적" {
    profile.resetForTest();
    defer profile.resetForTest();
    profile.addFromCsv("resolve");

    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    // external 경로로 호출 — filesystem 접근 없이 resolveInner 진입 확인.
    _ = try cache.resolve("/some/dir", "react", .static_import);

    try std.testing.expect(profile.count(.resolve) > 0);
    try std.testing.expect(profile.totalNs(.resolve) > 0);
}

test "resolve: profile .resolve 비활성 시 누적 없음" {
    profile.resetForTest();
    defer profile.resetForTest();

    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    _ = try cache.resolve("/some/dir", "react", .static_import);

    try std.testing.expectEqual(@as(u32, 0), profile.count(.resolve));
    try std.testing.expectEqual(@as(u64, 0), profile.totalNs(.resolve));
}

// resolve API (#1885 PR 4c-1) — ResolvedModule 직접 반환

fn freeResolvedPath(m: ResolvedModule) void {
    switch (m) {
        .file => |f| std.testing.allocator.free(f.path),
        .disabled => |d| std.testing.allocator.free(d.path),
        // Phase 1 cache 는 file/disabled 만 저장 — virtual/dataurl/external/custom variant
        // 가 cache 에서 반환되지 않음. 향후 그 variant 검증 테스트 추가 시 plugin_data
        // 등 payload 별 cleanup 을 helper 에 추가.
        else => {},
    }
}

test "resolve: 일반 파일 → .file variant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "foo.ts", .data = "" });
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const result = (try cache.resolve(dir_path, "./foo", .static_import)).?;
    defer freeResolvedPath(result);

    switch (result) {
        .file => |f| try std.testing.expect(std.mem.endsWith(u8, f.path, "foo.ts")),
        else => return error.TestUnexpectedResult,
    }
}

test "resolve: external pattern → null (resolve 와 동일 의미)" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    const result = try cache.resolve("/some/dir", "react", .static_import);
    try std.testing.expect(result == null);
}

test "resolve: not found → ModuleNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const result = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "resolveThreadSafe: 동작 검증" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "bar.ts", .data = "" });
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const result = (try cache.resolveThreadSafe(dir_path, "./bar", .static_import)).?;
    defer freeResolvedPath(result);

    switch (result) {
        .file => |f| try std.testing.expect(std.mem.endsWith(u8, f.path, "bar.ts")),
        else => return error.TestUnexpectedResult,
    }
}
