const std = @import("std");
const resolve_cache = @import("resolve_cache.zig");
const ResolveCache = resolve_cache.ResolveCache;
const matchGlob = resolve_cache.matchGlob;
const isNodeBuiltin = resolve_cache.isNodeBuiltin;

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
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{}, &.{});
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("node:fs"));
    try std.testing.expect(cache.isExternal("node:path"));
    try std.testing.expect(!cache.isExternal("react"));
}

test "isExternal: node builtins when platform=node" {
    var cache = ResolveCache.init(std.testing.allocator, .node, &.{}, &.{});
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
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{}, &.{});
    defer cache.deinit();

    try std.testing.expect(!cache.isExternal("fs"));
    try std.testing.expect(!cache.isExternal("path"));
}

test "isExternal: user patterns" {
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{ "react", "@mui/*" }, &.{});
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("react"));
    try std.testing.expect(cache.isExternal("@mui/material"));
    try std.testing.expect(!cache.isExternal("vue"));
}

test "resolve: external returns null" {
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{"react"}, &.{});
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

    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{}, &.{});
    defer cache.deinit();

    // 첫 번째 호출 (캐시 미스) — caller 소유
    const result1 = try cache.resolve(dir_path, "./foo", .static_import);
    try std.testing.expect(result1 != null);
    defer std.testing.allocator.free(result1.?.path);
    try std.testing.expect(std.mem.endsWith(u8, result1.?.path, "foo.ts"));

    // 두 번째 호출 (캐시 히트) — 별도 할당, caller 소유
    const result2 = try cache.resolve(dir_path, "./foo", .static_import);
    try std.testing.expect(result2 != null);
    defer std.testing.allocator.free(result2.?.path);
    try std.testing.expect(std.mem.endsWith(u8, result2.?.path, "foo.ts"));

    // 내용은 같지만 포인터는 다름 (각각 독립 할당)
    try std.testing.expectEqualStrings(result1.?.path, result2.?.path);
    try std.testing.expect(result1.?.path.ptr != result2.?.path.ptr);
}

test "resolve: not found cached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{}, &.{});
    defer cache.deinit();

    // 존재하지 않는 파일
    const r1 = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r1);

    // 두 번째 호출도 ModuleNotFound (캐시에서)
    const r2 = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r2);
}
