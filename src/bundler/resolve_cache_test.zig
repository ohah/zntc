const std = @import("std");
const resolve_cache = @import("resolve_cache.zig");
const ResolveCache = resolve_cache.ResolveCache;
const matchGlob = resolve_cache.matchGlob;
const matchPackageSubPath = resolve_cache.matchPackageSubPath;
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

test "matchGlob: doublestar and brace alternates" {
    try std.testing.expect(matchGlob("**/runtimeKind.{js,ts}", "src/runtimeKind.ts"));
    try std.testing.expect(matchGlob("**/runtimeKind.{js,ts}", "lib/module/runtimeKind.js"));
    try std.testing.expect(matchGlob("**/runtimeKind.{js,ts}", "runtimeKind.ts"));
    try std.testing.expect(!matchGlob("**/runtimeKind.{js,ts}", "src/runtimeKind.jsx"));
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
    try std.testing.expect(!cache.isExternal("./fs"));
    try std.testing.expect(!cache.isExternal("../path"));
    try std.testing.expect(!cache.isExternal("/project/fs"));
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

// ============================================================
// #1962 — external 패키지 sub-path 자동 매칭 (esbuild/rolldown 동등)
// ============================================================

test "matchPackageSubPath: exact 매칭은 false (matchGlob 책임)" {
    try std.testing.expect(!matchPackageSubPath("react", "react"));
}

test "matchPackageSubPath: sub-path 자동 external" {
    try std.testing.expect(matchPackageSubPath("react", "react/jsx-runtime"));
    try std.testing.expect(matchPackageSubPath("react", "react/jsx-dev-runtime"));
    try std.testing.expect(matchPackageSubPath("@mui/material", "@mui/material/Button"));
    // 깊은 sub-path 도 매칭 (esbuild/rolldown 동등)
    try std.testing.expect(matchPackageSubPath("react", "react/some/deep/path"));
}

test "matchPackageSubPath: prefix-only 비매칭 (false-positive 차단)" {
    // pattern="react" specifier="react-dom" — prefix 지만 sub-path 아님
    try std.testing.expect(!matchPackageSubPath("react", "react-dom"));
    try std.testing.expect(!matchPackageSubPath("react", "react-native"));
    // pattern="react" specifier="reactstrap" — 우연한 prefix
    try std.testing.expect(!matchPackageSubPath("react", "reactstrap"));
}

test "matchPackageSubPath: wildcard 보유 패턴은 자동 확장 안 함" {
    // 사용자가 명시적으로 sub-path 매칭을 작성한 경우 (`react/*`) 매칭은 matchGlob 가 담당
    try std.testing.expect(!matchPackageSubPath("react/*", "react/jsx-runtime"));
    try std.testing.expect(!matchPackageSubPath("@mui/*", "@mui/material/Button"));
}

test "matchPackageSubPath: 빈 specifier / pattern 안전성" {
    try std.testing.expect(!matchPackageSubPath("", ""));
    try std.testing.expect(!matchPackageSubPath("", "react"));
    try std.testing.expect(!matchPackageSubPath("react", ""));
}

test "isExternal: sub-path 가 자동 external (#1962)" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("react"));
    try std.testing.expect(cache.isExternal("react/jsx-runtime"));
    try std.testing.expect(cache.isExternal("react/jsx-dev-runtime"));
    // 우연한 prefix 는 external 아님
    try std.testing.expect(!cache.isExternal("react-dom"));
    try std.testing.expect(!cache.isExternal("reactstrap"));
}

test "isExternal: scoped 패키지 sub-path 도 자동 external (#1962)" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"@babel/runtime"} });
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("@babel/runtime"));
    try std.testing.expect(cache.isExternal("@babel/runtime/helpers/extends"));
    // 다른 scope 는 external 아님
    try std.testing.expect(!cache.isExternal("@babel/core"));
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

    // PR resolve interning: 결과의 path 는 cache.path_pool 소유 (borrow only, free 금지).
    // cache.deinit() 시 pool 도 일괄 reclaim.

    // 첫 번째 호출 (캐시 미스)
    const result1 = (try cache.resolve(dir_path, "./foo", .static_import)).?;
    const path1 = switch (result1) {
        .file => |f| f.path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.endsWith(u8, path1, "foo.ts"));

    // 두 번째 호출 (캐시 히트) — interning 후엔 *동일 ptr* 반환.
    const result2 = (try cache.resolve(dir_path, "./foo", .static_import)).?;
    const path2 = switch (result2) {
        .file => |f| f.path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.endsWith(u8, path2, "foo.ts"));

    // interning: 내용 동일 + ptr 동일 (single source of truth).
    try std.testing.expectEqualStrings(path1, path2);
    try std.testing.expect(path1.ptr == path2.ptr);
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

// resolve API (#1885 PR 4c-1) — ResolvedModule 직접 반환.
// PR resolve interning: ResolvedModule.path 는 cache.path_pool 소유 (borrow only).
// 옛 freeResolvedPath helper 제거 — caller 가 free 호출 안 함, cache.deinit() 이 일괄 reclaim.
fn freeResolvedPath(m: ResolvedModule) void {
    _ = m;
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

// ============================================================
// #3759 — internResolvedModule .virtual owns_path discriminator
// ============================================================

test "internResolvedModule: .virtual owns_path=true 시 원본 free + intern (#3759)" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // NAPI bridge 처럼 graph_allocator (= testing.allocator) 로 dupe 한 path 시뮬레이트.
    const dup_path = try testing.allocator.dupe(u8, "\x00plugin:virtual-mod");

    const result = try cache.internResolvedModule(.{ .virtual = .{
        .path = dup_path,
        .owns_path = true,
    } });

    // 반환된 path 는 path_pool 의 interned slice — dup_path 와 *다른* 포인터.
    switch (result) {
        .virtual => |v| {
            try testing.expectEqualStrings("\x00plugin:virtual-mod", v.path);
            try testing.expect(v.path.ptr != dup_path.ptr); // ← intern 확인
            try testing.expect(!v.owns_path); // ← 반환값은 항상 owns_path=false (caller borrow)
        },
        else => return error.TestUnexpectedResult,
    }
    // testing.allocator 의 leak detection: dup_path 가 free 안 되었다면 test fail.
}

test "internResolvedModule: .virtual owns_path=false 시 borrow 유지 (#3759)" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // runtime_helper_modules 처럼 static literal / parse_arena borrow 시뮬레이트.
    const static_path: []const u8 = "\x00zntc:runtime/extends";

    const result = try cache.internResolvedModule(.{
        .virtual = .{
            .path = static_path,
            .owns_path = false, // ← borrow only — bundler 가 free 시도 금지
        },
    });

    switch (result) {
        .virtual => |v| {
            try testing.expectEqualStrings("\x00zntc:runtime/extends", v.path);
            // path_pool 에 dupe 되어 *다른* slice 반환.
            try testing.expect(v.path.ptr != static_path.ptr);
            try testing.expect(!v.owns_path);
        },
        else => return error.TestUnexpectedResult,
    }
    // 만약 fix 가 owns_path 무시하고 항상 free 했다면 static literal free → panic.
    // 통과 자체가 borrow 시맨틱 보존 증거.
}
