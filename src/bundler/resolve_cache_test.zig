const std = @import("std");
const resolve_cache = @import("resolve_cache.zig");
const ResolveCache = resolve_cache.ResolveCache;
const matchGlob = resolve_cache.matchGlob;
const matchPackageSubPath = resolve_cache.matchPackageSubPath;
const isNodeBuiltin = resolve_cache.isNodeBuiltin;
const normalizeWorkerSpecifier = resolve_cache.normalizeWorkerSpecifier;
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

test "#4380 matchGlob: 긴 brace alternative(>4096) 도 silent skip 없이 매치" {
    // prefix+alt+suffix 가 4096 stack buffer 를 초과하는 긴 alternative. 과거엔 silent skip 해
    // 매치 실패(false)였다 — heap fallback 으로 정확히 매치.
    const long = "x" ** 5000;
    try std.testing.expect(matchGlob("{" ++ long ++ "}", long));
    // 매치 안 되는 긴 alt 는 정상적으로 false (crash/skip 없이).
    try std.testing.expect(!matchGlob("{" ++ long ++ "}", "y" ** 5000));
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

    const result = try cache.resolve(std.testing.io, "/some/dir", "react", .static_import);
    try std.testing.expect(result == null);
}

test "resolve: cache hit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // 파일 생성
    const file = try tmp.dir.createFile(std.testing.io, "foo.ts", .{});
    file.close(std.testing.io);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    // PR resolve interning: 결과의 path 는 cache.path_pool 소유 (borrow only, free 금지).
    // cache.deinit() 시 pool 도 일괄 reclaim.

    // 첫 번째 호출 (캐시 미스)
    const result1 = (try cache.resolve(std.testing.io, dir_path, "./foo", .static_import)).?;
    const path1 = switch (result1) {
        .file => |f| f.path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.endsWith(u8, path1, "foo.ts"));

    // 두 번째 호출 (캐시 히트) — interning 후엔 *동일 ptr* 반환.
    const result2 = (try cache.resolve(std.testing.io, dir_path, "./foo", .static_import)).?;
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

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    // 존재하지 않는 파일
    const r1 = cache.resolve(std.testing.io, dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r1);

    // 두 번째 호출도 ModuleNotFound (캐시에서)
    const r2 = cache.resolve(std.testing.io, dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r2);
}

test "resolve: profile .resolve 활성 시 누적" {
    profile.resetForTest();
    defer profile.resetForTest();
    profile.addFromCsv("resolve");
    profile.setIoForTest(std.testing.io);

    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    // external 경로로 호출 — filesystem 접근 없이 resolveInner 진입 확인.
    _ = try cache.resolve(std.testing.io, "/some/dir", "react", .static_import);

    try std.testing.expect(profile.count(.resolve) > 0);
    try std.testing.expect(profile.totalNs(.resolve) > 0);
}

test "resolve: profile .resolve 비활성 시 누적 없음" {
    profile.resetForTest();
    defer profile.resetForTest();

    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    _ = try cache.resolve(std.testing.io, "/some/dir", "react", .static_import);

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

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "foo.ts", .data = "" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const result = (try cache.resolve(std.testing.io, dir_path, "./foo", .static_import)).?;
    defer freeResolvedPath(result);

    switch (result) {
        .file => |f| try std.testing.expect(std.mem.endsWith(u8, f.path, "foo.ts")),
        else => return error.TestUnexpectedResult,
    }
}

test "resolve: external pattern → null (resolve 와 동일 의미)" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();

    const result = try cache.resolve(std.testing.io, "/some/dir", "react", .static_import);
    try std.testing.expect(result == null);
}

test "resolve: not found → ModuleNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const result = cache.resolve(std.testing.io, dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "resolveThreadSafe: 동작 검증" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bar.ts", .data = "" });
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const result = (try cache.resolveThreadSafe(std.testing.io, dir_path, "./bar", .static_import)).?;
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
        .owner = .owned,
    } });

    // 반환된 path 는 path_pool 의 interned slice — dup_path 와 *다른* 포인터.
    switch (result) {
        .virtual => |v| {
            try testing.expectEqualStrings("\x00plugin:virtual-mod", v.path);
            try testing.expect(v.path.ptr != dup_path.ptr); // ← intern 확인
            try testing.expect(v.owner == .borrowed); // ← 반환값은 항상 owns_path=false (caller borrow)
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
            .owner = .borrowed, // ← borrow only — bundler 가 free 시도 금지
        },
    });

    switch (result) {
        .virtual => |v| {
            try testing.expectEqualStrings("\x00zntc:runtime/extends", v.path);
            // path_pool 에 dupe 되어 *다른* slice 반환.
            try testing.expect(v.path.ptr != static_path.ptr);
            try testing.expect(v.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }
    // 만약 fix 가 owns_path 무시하고 항상 free 했다면 static literal free → panic.
    // 통과 자체가 borrow 시맨틱 보존 증거.
}

// .file / .disabled owns_path 대칭화 (multi-angle finding) — .virtual 와 같은 패턴.
test "internResolvedModule: .file owns_path=true 시 원본 free + intern" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    const dup_path = try testing.allocator.dupe(u8, "/abs/file.ts");
    const dup_rd = try testing.allocator.dupe(u8, "/abs");

    const result = try cache.internResolvedModule(.{ .file = .{
        .path = dup_path,
        .resolve_dir = dup_rd,
        .module_type = .js,
        .owner = .owned,
    } });

    switch (result) {
        .file => |f| {
            try testing.expectEqualStrings("/abs/file.ts", f.path);
            try testing.expect(f.path.ptr != dup_path.ptr);
            try testing.expect(f.resolve_dir != null);
            try testing.expect(f.resolve_dir.?.ptr != dup_rd.ptr);
            try testing.expect(f.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }
    // testing.allocator leak detection: dup_path/dup_rd 가 free 안 되면 fail.
}

test "internResolvedModule: .file owns_path=false 시 borrow 유지" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // future plugin 이 static literal / parse_arena borrow path 를 .file 로 반환하는 케이스.
    const static_path: []const u8 = "/abs/borrowed.ts";

    const result = try cache.internResolvedModule(.{ .file = .{
        .path = static_path,
        .module_type = .js,
        .owner = .borrowed,
    } });

    switch (result) {
        .file => |f| {
            try testing.expectEqualStrings("/abs/borrowed.ts", f.path);
            try testing.expect(f.path.ptr != static_path.ptr); // intern 됐음
            try testing.expect(f.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }
    // static literal free 안 됐다는 게 통과 자체로 증명 (free 시 panic).
}

test "internResolvedModule: .disabled owns_path=true / false" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // owns_path=true (현 production 동작 — 모든 caller dupe).
    const dup_path = try testing.allocator.dupe(u8, "/disabled/mod");
    const r1 = try cache.internResolvedModule(.{ .disabled = .{
        .path = dup_path,
        .module_type = .js,
        .owner = .owned,
    } });
    switch (r1) {
        .disabled => |d| try testing.expect(d.path.ptr != dup_path.ptr),
        else => return error.TestUnexpectedResult,
    }

    // owns_path=false (future borrow).
    const static_path: []const u8 = "/disabled/static";
    const r2 = try cache.internResolvedModule(.{ .disabled = .{
        .path = static_path,
        .module_type = .js,
        .owner = .borrowed,
    } });
    switch (r2) {
        .disabled => |d| {
            try testing.expectEqualStrings("/disabled/static", d.path);
            try testing.expect(d.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }
}

// .external / .custom owns_path 대칭화 — future plugin layer 안전성.
test "internResolvedModule: .external owns_path=true / false" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // owns_path=true
    const dup_path = try testing.allocator.dupe(u8, "react");
    const r1 = try cache.internResolvedModule(.{ .external = .{
        .path = dup_path,
        .owner = .owned,
    } });
    switch (r1) {
        .external => |e| {
            try testing.expectEqualStrings("react", e.path);
            try testing.expect(e.path.ptr != dup_path.ptr);
            try testing.expect(e.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }

    // owns_path=false
    const static_path: []const u8 = "node:fs";
    const r2 = try cache.internResolvedModule(.{ .external = .{
        .path = static_path,
        .owner = .borrowed,
    } });
    switch (r2) {
        .external => |e| {
            try testing.expectEqualStrings("node:fs", e.path);
            try testing.expect(e.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "internResolvedModule: .custom owns_path=true / false (name + path)" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // owns_path=true — name + path 모두 free.
    const dup_name = try testing.allocator.dupe(u8, "my-ns");
    const dup_path = try testing.allocator.dupe(u8, "/abs/custom");
    const r1 = try cache.internResolvedModule(.{ .custom = .{
        .name = dup_name,
        .path = dup_path,
        .owner = .owned,
    } });
    switch (r1) {
        .custom => |c| {
            try testing.expectEqualStrings("my-ns", c.name);
            try testing.expectEqualStrings("/abs/custom", c.path);
            try testing.expect(c.name.ptr != dup_name.ptr);
            try testing.expect(c.path.ptr != dup_path.ptr);
            try testing.expect(c.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }

    // owns_path=false — borrow.
    const r2 = try cache.internResolvedModule(.{ .custom = .{
        .name = "static-ns",
        .path = "/abs/static",
        .owner = .borrowed,
    } });
    switch (r2) {
        .custom => |c| {
            try testing.expectEqualStrings("static-ns", c.name);
            try testing.expectEqualStrings("/abs/static", c.path);
            try testing.expect(c.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }
}

// .dataurl Owner — mime 은 path_pool intern, data 는 dataurl_arena dupe (deferred 5).
test "internResolvedModule: .dataurl .owned / .borrowed 모두 cache-owned data 반환" {
    const testing = std.testing;
    var cache = ResolveCache.init(testing.allocator, .{});
    defer cache.deinit();

    // .owned: caller alloc → 원본 free, mime/data 모두 cache 가 자체 owner.
    const dup_mime = try testing.allocator.dupe(u8, "image/png");
    const dup_data = try testing.allocator.dupe(u8, "BASE64DATA");
    const r1 = try cache.internResolvedModule(.{ .dataurl = .{
        .mime = dup_mime,
        .data = dup_data,
        .owner = .owned,
    } });
    switch (r1) {
        .dataurl => |du| {
            try testing.expectEqualStrings("image/png", du.mime);
            try testing.expect(du.mime.ptr != dup_mime.ptr); // mime intern (path_pool)
            try testing.expect(du.owner == .borrowed); // 반환은 항상 cache-borrow
            // (deferred 5 fix) data 는 더 이상 "" placeholder 가 아닌 *실제* data — cache
            // 의 dataurl_arena 에 dupe 됨.
            try testing.expectEqualStrings("BASE64DATA", du.data);
            try testing.expect(du.data.ptr != dup_data.ptr); // 별도 arena dupe
        },
        else => return error.TestUnexpectedResult,
    }

    // .borrowed: static literal — 원본 free 안 함. data 는 dataurl_arena dupe.
    const r2 = try cache.internResolvedModule(.{ .dataurl = .{
        .mime = "text/plain",
        .data = "literal-data",
        .owner = .borrowed,
    } });
    switch (r2) {
        .dataurl => |du| {
            try testing.expectEqualStrings("text/plain", du.mime);
            try testing.expectEqualStrings("literal-data", du.data);
            try testing.expect(du.owner == .borrowed);
        },
        else => return error.TestUnexpectedResult,
    }

    // .borrowed + heap-alloc — caller borrow 라도 data 는 *cache 가 dupe* 해 lifetime
    // 독립. caller 가 그 사이 free 해도 cache 반환값 안전 (이전 PR #3767 보다 더 강화).
    //
    // (review finding) 실제 lifetime 독립을 증명: dupe 직후 borrow_data 를 *즉시* free
    // 한 다음 du.data 를 사용. dupe 누락 회귀 시 testing.allocator 가 freed read 잡아냄
    // (이전엔 defer 라 test 종료 시점에만 free → false-positive).
    const borrow_data = try testing.allocator.dupe(u8, "heap-borrow-data");
    const r3 = try cache.internResolvedModule(.{ .dataurl = .{
        .mime = "application/octet-stream",
        .data = borrow_data,
        .owner = .borrowed,
    } });
    testing.allocator.free(borrow_data); // 즉시 free — du.data 가 진짜 독립인지 확인
    switch (r3) {
        .dataurl => |du| {
            try testing.expect(du.data.ptr != borrow_data.ptr); // arena dupe (lifetime 독립)
            try testing.expectEqualStrings("heap-borrow-data", du.data);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ============================================================
// deferred 7 — OOM injection: errdefer / rollback 경로 회귀 가드
// ============================================================
//
// 모든 variant 의 .owned 경로에서 intern 실패 시 errdefer 가 원본 input 을 free
// 하는지 검증. testing.allocator leak detector 가 input 슬라이스 미해제 시 fail.

test "internResolvedModule: .file OOM 시 errdefer 가 path + resolve_dir 둘 다 free" {
    const testing = std.testing;
    // fail_index=0: 첫 alloc (internPair 안 path 또는 resolve_dir dupe) 부터 OOM.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cache = ResolveCache.init(failing.allocator(), .{});
    defer cache.deinit();

    const dup_path = try testing.allocator.dupe(u8, "/abs/file.ts");
    const dup_rd = try testing.allocator.dupe(u8, "/abs");
    // cache.allocator 가 failing 이라 path_pool.intern (path_pool 의 arena.dupe) 가 OOM.
    const r = cache.internResolvedModule(.{ .file = .{
        .path = dup_path,
        .resolve_dir = dup_rd,
        .module_type = .js,
        .owner = .owned,
    } });
    // OOM 반환 후, cache 내부 errdefer 가 dup_path/dup_rd 를 cache.allocator=failing
    // 으로 free 시도 → testing.allocator passthrough → ledger 일관.
    try testing.expectError(error.OutOfMemory, r);
}

test "internResolvedModule: .virtual OOM 시 errdefer 가 path free" {
    const testing = std.testing;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cache = ResolveCache.init(failing.allocator(), .{});
    defer cache.deinit();

    const dup_path = try testing.allocator.dupe(u8, "\x00plugin:foo");
    const r = cache.internResolvedModule(.{ .virtual = .{
        .path = dup_path,
        .owner = .owned,
    } });
    try testing.expectError(error.OutOfMemory, r);
}

test "internResolvedModule: .external OOM 시 errdefer 가 path free" {
    const testing = std.testing;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cache = ResolveCache.init(failing.allocator(), .{});
    defer cache.deinit();

    const dup_path = try testing.allocator.dupe(u8, "react");
    const r = cache.internResolvedModule(.{ .external = .{
        .path = dup_path,
        .owner = .owned,
    } });
    try testing.expectError(error.OutOfMemory, r);
}

test "internResolvedModule: .custom OOM 시 errdefer 가 name + path 둘 다 free" {
    const testing = std.testing;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cache = ResolveCache.init(failing.allocator(), .{});
    defer cache.deinit();

    const dup_name = try testing.allocator.dupe(u8, "my-ns");
    const dup_path = try testing.allocator.dupe(u8, "/abs/custom");
    const r = cache.internResolvedModule(.{ .custom = .{
        .name = dup_name,
        .path = dup_path,
        .owner = .owned,
    } });
    try testing.expectError(error.OutOfMemory, r);
}

test "internResolvedModule: .disabled OOM 시 errdefer 가 path free" {
    const testing = std.testing;
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cache = ResolveCache.init(failing.allocator(), .{});
    defer cache.deinit();

    const dup_path = try testing.allocator.dupe(u8, "/disabled/mod");
    const r = cache.internResolvedModule(.{ .disabled = .{
        .path = dup_path,
        .module_type = .js,
        .owner = .owned,
    } });
    try testing.expectError(error.OutOfMemory, r);
}

test "internResolvedModule: .dataurl mime OOM 시 errdefer 가 mime + data 둘 다 free" {
    const testing = std.testing;
    // mime intern 단계에서 OOM (path_pool 의 첫 alloc).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var cache = ResolveCache.init(failing.allocator(), .{});
    defer cache.deinit();

    const dup_mime = try testing.allocator.dupe(u8, "image/png");
    const dup_data = try testing.allocator.dupe(u8, "BASE64DATA");
    const r = cache.internResolvedModule(.{ .dataurl = .{
        .mime = dup_mime,
        .data = dup_data,
        .owner = .owned,
    } });
    try testing.expectError(error.OutOfMemory, r);
}

// ============================================================
// #4483 — worker specifier 는 URL 상대 참조 (`./` 생략 가능)
// ============================================================

/// 테스트 헬퍼 — worker kind 정규화 결과. null = 정규화 대상 아님(원문 사용).
fn normWorker(buf: []u8, specifier: []const u8) ?[]const u8 {
    return normalizeWorkerSpecifier(.worker, specifier, buf);
}

test "#4483 normalizeWorkerSpecifier: bare 상대 지정자에 ./ 를 붙인다" {
    var buf: [1024]u8 = undefined;
    // `new URL("x.worker.js", import.meta.url)` 의 base 는 모듈 자신의 URL →
    // `./x.worker.js` 와 같은 파일. resolver 가 npm 패키지로 오인하지 않게 정규화.
    try std.testing.expectEqualStrings("./x.worker.js", normWorker(&buf, "x.worker.js").?);
    try std.testing.expectEqualStrings("./sub/dir/w.js", normWorker(&buf, "sub/dir/w.js").?);
    // monaco-editor 의 실제 형태 (cssMode.js → css.worker.js).
    try std.testing.expectEqualStrings("./css.worker.js", normWorker(&buf, "css.worker.js").?);
    // `..foo` 는 상대 경로가 아니라 그냥 파일명 — `./..foo` 가 맞다.
    try std.testing.expectEqualStrings("./..foo.js", normWorker(&buf, "..foo.js").?);
}

test "#4483 normalizeWorkerSpecifier: 이미 상대 경로면 정규화 안 함" {
    var buf: [1024]u8 = undefined;
    try std.testing.expect(normWorker(&buf, "./w.js") == null);
    try std.testing.expect(normWorker(&buf, "../w.js") == null);
    try std.testing.expect(normWorker(&buf, "../../a/w.js") == null);
}

test "#4483 normalizeWorkerSpecifier: scheme/root-absolute/protocol-relative 는 건드리지 않는다" {
    var buf: [1024]u8 = undefined;
    // scheme 있는 절대 URL — base 를 무시하는 valid worker 소스.
    try std.testing.expect(normWorker(&buf, "https://cdn.example.com/w.js") == null);
    try std.testing.expect(normWorker(&buf, "http://a/w.js") == null);
    try std.testing.expect(normWorker(&buf, "data:text/javascript,1") == null);
    try std.testing.expect(normWorker(&buf, "blob:abc") == null);
    try std.testing.expect(normWorker(&buf, "chrome-extension://id/w.js") == null);
    // root-absolute + protocol-relative — origin 기준이라 파일 시스템 상대가 아니다.
    try std.testing.expect(normWorker(&buf, "/abs/w.js") == null);
    try std.testing.expect(normWorker(&buf, "//cdn.example.com/w.js") == null);
    // query/fragment 가 붙은 지정자는 전부 제외.
    // - `?worker`/`?sharedworker` 를 정규화하면 resolver 가 형제 파일로 해석해
    //   **WorkerWrapper 팩토리** 청크를 만든다 (worker 본문이 아니라) → 워커가 응답 안 함.
    // - `?v=1` 같은 미지의 쿼리는 resolver 가 벗기지 못해 어차피 못 연다 (`./` 를 붙여도 동일).
    try std.testing.expect(normWorker(&buf, "w.js?worker") == null);
    try std.testing.expect(normWorker(&buf, "w.js?v=1") == null);
    try std.testing.expect(normWorker(&buf, "w.js#frag") == null);
    try std.testing.expect(normWorker(&buf, "?v=1") == null);
    try std.testing.expect(normWorker(&buf, "#frag") == null);
    try std.testing.expect(normWorker(&buf, "") == null);
}

test "#4483 normalizeWorkerSpecifier: worker 가 아닌 kind 는 bare 를 그대로 (npm 패키지)" {
    var buf: [1024]u8 = undefined;
    // import/require 의 bare 는 npm 패키지 — 정규화하면 resolution 이 깨진다.
    try std.testing.expect(normalizeWorkerSpecifier(.static_import, "react", &buf) == null);
    try std.testing.expect(normalizeWorkerSpecifier(.dynamic_import, "react-dom/client", &buf) == null);
    try std.testing.expect(normalizeWorkerSpecifier(.require, "lodash", &buf) == null);
    // CSS url() 의 bare 는 여전히 패키지 경로로 resolve 된다 (별도 이슈) — 건드리지 않는다.
    try std.testing.expect(normalizeWorkerSpecifier(.css_url, "logo.png", &buf) == null);
}

test "#4483 normalizeWorkerSpecifier: 버퍼보다 긴 specifier 는 정규화 생략 (fallback)" {
    var small: [8]u8 = undefined;
    // `"./" + spec` 이 버퍼에 안 들어가면 정규화를 포기 → caller 가 원문으로 resolve (기존 동작).
    try std.testing.expect(normWorker(&small, "verylongspecifier.js") == null);
    // 경계: len + 2 == buf.len 은 정규화 성공.
    var exact: [8]u8 = undefined;
    try std.testing.expectEqualStrings("./abcdef", normWorker(&exact, "abcdef").?);
}

test "#4483 isExternal: --packages=external 의 \"bare = 패키지\" 자동 규칙은 worker 에 적용 안 함" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .packages_external = true });
    defer cache.deinit();

    // 일반 import 의 bare 는 npm 패키지 → external (기존 동작 유지).
    try std.testing.expect(cache.isExternalForKind("react", .static_import));
    try std.testing.expect(cache.isExternalForKind("css.worker.js", .static_import));
    // worker 의 bare 는 URL 상대 참조지 패키지 이름이 아니다 → 삼키면 안 된다.
    // (이 규칙이 없으면 `--packages=external` 을 켠 순간 형제 worker 가 통째로 404 가 된다.)
    try std.testing.expect(!cache.isExternalForKind("css.worker.js", .worker));
}

test "#4483 isExternal: 사용자가 명시한 --external 패턴은 worker 에도 그대로 적용" {
    const patterns = [_][]const u8{"*.worker.js"};
    var cache = ResolveCache.init(std.testing.allocator, .{ .packages_external = true });
    defer cache.deinit();
    cache.setExternalPatterns(&patterns);

    // 자동 규칙은 빼지만 사용자 의사는 존중한다.
    try std.testing.expect(cache.isExternalForKind("css.worker.js", .worker));
}

test "#4483 resolve: bare worker specifier 가 형제 파일로 해석된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const f = try tmp.dir.createFile(std.testing.io, "css.worker.js", .{});
    f.close(std.testing.io);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    // `./` 없는 worker 지정자 → 형제 파일. (static_import 였다면 npm 패키지라 실패해야 정상.)
    const worker = try cache.resolve(std.testing.io, dir_path, "css.worker.js", .worker);
    try std.testing.expect(worker != null);
    try std.testing.expect(std.mem.endsWith(u8, worker.?.file.path, "css.worker.js"));

    // 같은 파일을 `./` 로 가리켜도 같은 경로.
    const dotted = try cache.resolve(std.testing.io, dir_path, "./css.worker.js", .worker);
    try std.testing.expectEqualStrings(worker.?.file.path, dotted.?.file.path);

    // worker 가 아닌 kind 는 정규화 대상이 아니다 → bare 는 npm 패키지 → 못 찾음.
    try std.testing.expectError(
        error.ModuleNotFound,
        cache.resolve(std.testing.io, dir_path, "css.worker.js", .static_import),
    );
}

test "#4483 resolve: 형제 파일이 없으면 원문(패키지 경로) 폴백" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // node_modules/wpkg/w.js — `new Worker(new URL("wpkg/w.js", import.meta.url))` 형태의
    // 패키지 경로 worker. 정규화("./wpkg/w.js") 는 실패하고 원문 폴백이 이걸 찾아야 한다.
    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/wpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/wpkg/package.json", .data = "{\"name\":\"wpkg\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/wpkg/w.js", .data = "self.onmessage=()=>{};" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "wpkg/w.js", .worker);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") != null);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?.file.path, "w.js"));

    // 아무 데도 없는 worker 는 여전히 ModuleNotFound (폴백이 에러를 삼키지 않는다).
    try std.testing.expectError(
        error.ModuleNotFound,
        cache.resolve(std.testing.io, dir_path, "nope.worker.js", .worker),
    );
}

test "#4483 resolve: 사용자 external 패턴은 원문 철자로도 계속 먹힌다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const f = try tmp.dir.createFile(std.testing.io, "css.worker.js", .{});
    f.close(std.testing.io);

    // `--external:*.worker.js` — 사용자가 원문 철자(bare)로 건 패턴. 정규화("./css.worker.js")
    // 뒤에 매칭했다면 `*` 가 `/` 를 안 넘어서 조용히 무효가 됐을 것이다.
    var cache = ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"*.worker.js"} });
    defer cache.deinit();

    // 형제 파일이 실재해도 external 의사가 우선 → null (번들에 넣지 않음).
    try std.testing.expect(try cache.resolve(std.testing.io, dir_path, "css.worker.js", .worker) == null);

    // 패턴 없는 cache 는 정상적으로 형제 파일을 찾는다 (위 null 이 resolve 실패가 아님을 보장).
    var plain = ResolveCache.init(std.testing.allocator, .{});
    defer plain.deinit();
    try std.testing.expect(try plain.resolve(std.testing.io, dir_path, "css.worker.js", .worker) != null);
}
