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

/// resolver 의 `url_relative` 플래그가 켜지는 조건 (#4604).
/// ⚠️ 술어를 여기서 재구현하면 프로덕션 게이트가 바뀌어도 아래 테스트가 안 깨진다 —
/// `ResolveCache` 가 실제로 부르는 것과 **같은 함수**를 쓴다.
const urlRelative = resolve_cache.urlRelativeFor;

test "#4604 url_relative: bare 상대 지정자에 켜진다" {
    // `new URL("x.worker.js", import.meta.url)` 의 base 는 모듈 자신의 URL → `./x.worker.js`
    // 와 같은 파일. resolver 가 npm 패키지로 오인하지 않게 형제를 먼저 보게 한다.
    try std.testing.expect(urlRelative(.worker, "x.worker.js"));
    try std.testing.expect(urlRelative(.worker, "sub/dir/w.js"));
    // monaco-editor 의 실제 형태 (cssMode.js → css.worker.js).
    try std.testing.expect(urlRelative(.worker, "css.worker.js"));
    // `..foo` 는 상대 경로가 아니라 그냥 파일명.
    try std.testing.expect(urlRelative(.worker, "..foo.js"));
    // CSS url() 도 같다 (#4485).
    try std.testing.expect(urlRelative(.css_url, "logo.png"));
    try std.testing.expect(urlRelative(.css_url, "img/hero.png"));
}

test "#4604 url_relative: 이미 상대 경로면 꺼진다 (일반 경로 조합이 처리)" {
    try std.testing.expect(!urlRelative(.worker, "./w.js"));
    try std.testing.expect(!urlRelative(.worker, "../w.js"));
    try std.testing.expect(!urlRelative(.worker, "../../a/w.js"));
    try std.testing.expect(!urlRelative(.css_url, "./logo.png"));
}

test "#4604 url_relative: scheme/root-absolute/protocol-relative 는 건드리지 않는다" {
    // scheme 있는 절대 URL — base 를 무시하는 valid worker 소스.
    try std.testing.expect(!urlRelative(.worker, "https://cdn.example.com/w.js"));
    try std.testing.expect(!urlRelative(.worker, "http://a/w.js"));
    try std.testing.expect(!urlRelative(.worker, "data:text/javascript,1"));
    try std.testing.expect(!urlRelative(.worker, "blob:abc"));
    try std.testing.expect(!urlRelative(.worker, "chrome-extension://id/w.js"));
    // root-absolute + protocol-relative — origin 기준이라 파일 시스템 상대가 아니다.
    try std.testing.expect(!urlRelative(.worker, "/abs/w.js"));
    try std.testing.expect(!urlRelative(.worker, "//cdn.example.com/w.js"));
    // query/fragment 가 붙은 지정자는 전부 제외.
    // - `?worker`/`?sharedworker` 를 형제로 해석하면 **WorkerWrapper 팩토리** 청크가 잡힌다
    //   (worker 본문이 아니라) → 워커가 응답 안 함.
    // - `?v=1` 같은 미지의 쿼리는 resolver 가 벗기지 못해 어차피 못 연다.
    try std.testing.expect(!urlRelative(.worker, "w.js?worker"));
    try std.testing.expect(!urlRelative(.worker, "w.js?v=1"));
    try std.testing.expect(!urlRelative(.worker, "w.js#frag"));
    try std.testing.expect(!urlRelative(.worker, "?v=1"));
    try std.testing.expect(!urlRelative(.worker, "#frag"));
    try std.testing.expect(!urlRelative(.worker, ""));
    try std.testing.expect(!urlRelative(.css_url, "https://cdn/a.png"));
    try std.testing.expect(!urlRelative(.css_url, "/abs.png"));
}

test "#4604 url_relative: import/require kind 는 bare 를 그대로 (npm 패키지)" {
    // import/require 의 bare 는 npm 패키지 — 형제로 가면 resolution 이 깨진다.
    try std.testing.expect(!urlRelative(.static_import, "react"));
    try std.testing.expect(!urlRelative(.dynamic_import, "react-dom/client"));
    try std.testing.expect(!urlRelative(.require, "lodash"));
    try std.testing.expect(!urlRelative(.side_effect, "normalize.css"));
    // 같은 철자라도 kind 가 URL 이면 켜진다 — 갈리는 축이 kind 라는 것 자체를 박제한다.
    try std.testing.expect(urlRelative(.css_url, "normalize.css"));
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

// ============================================================
// #4485 — CSS `url()` 도 URL 상대 참조 (`./` 생략 가능)
//
// CSS 스펙상 `url()` 의 base 는 **스타일시트 자신의 URL** 이라
// `url(logo.png)` 와 `url(./logo.png)` 는 같은 파일을 가리켜야 한다.
// #4483 이 worker 에 쓴 구조를 그대로 확장한 것 — 해석 순서는 #4604 에서
// `--alias` > 형제 > 패키지 로 정리했다 (esbuild·rspack 실측).
// ============================================================

test "#4604 url_relative: css_url 의 bare 도 형제 우선 대상" {
    // #4483 은 css_url 을 일부러 뺐고(bare 가 패키지로도 해석돼 우선순위 결정이 필요했다),
    // #4485 가 "패키지 우선 + `./` 폴백" 으로 넣었다가, #4604 에서 esbuild·rspack 실측에
    // 맞춰 형제 우선으로 정리했다.
    try std.testing.expect(urlRelative(.css_url, "logo.png"));
    try std.testing.expect(urlRelative(.css_url, "img/logo.png"));
    try std.testing.expect(urlRelative(.css_url, "fonts/x.woff2"));
    // 패키지 경로처럼 보이는 것도 대상이다 — 형제가 없으면 아래 node_modules 로 폴백한다.
    try std.testing.expect(urlRelative(.css_url, "imgpkg/pic.png"));
}

test "#4604 url_relative: css_url 의 상대/절대/scheme 은 건드리지 않는다" {
    // 이미 명시적 상대 경로 — 일반 경로 조합이 그대로 처리한다.
    try std.testing.expect(!urlRelative(.css_url, "./logo.png"));
    try std.testing.expect(!urlRelative(.css_url, "../assets/logo.png"));
    // root-absolute — public 디렉토리 규약 (loaders 가 애초에 record 도 안 만든다).
    try std.testing.expect(!urlRelative(.css_url, "/logo.png"));
    try std.testing.expect(!urlRelative(.css_url, "//cdn.example.com/logo.png"));
    // scheme 있는 절대 URL — 그대로 방출돼야 한다.
    try std.testing.expect(!urlRelative(.css_url, "https://cdn.example.com/z.png"));
    try std.testing.expect(!urlRelative(.css_url, "data:image/png;base64,iVBOR"));
    try std.testing.expect(!urlRelative(.css_url, "blob:abc"));
}

test "#4485 resolve: bare css url() 이 스타일시트 형제 파일로 해석된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logo.png", .data = "PNG" });

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    // `url(logo.png)` — `./` 없는 bare. 지금까지는 npm 패키지로 오인돼 ModuleNotFound 였다.
    const bare = try cache.resolve(std.testing.io, dir_path, "logo.png", .css_url);
    try std.testing.expect(bare != null);
    try std.testing.expect(std.mem.endsWith(u8, bare.?.file.path, "logo.png"));

    // `url(./logo.png)` 와 **같은 파일**로 수렴해야 한다 (CSS 스펙).
    const dotted = try cache.resolve(std.testing.io, dir_path, "./logo.png", .css_url);
    try std.testing.expectEqualStrings(bare.?.file.path, dotted.?.file.path);

    // 아무 데도 없는 자산은 여전히 ModuleNotFound (폴백이 에러를 삼키지 않는다 → warning).
    try std.testing.expectError(
        error.ModuleNotFound,
        cache.resolve(std.testing.io, dir_path, "nope.png", .css_url),
    );
}

test "#4604 resolve: bare css url() 은 형제가 동명 패키지를 이긴다" {
    // #4485 는 패키지 우선으로 뒀었다 (형제가 패키지를 가리는 것을 회귀로 봤다).
    // esbuild·rspack 을 같은 픽스처로 실측한 결과 둘 다 형제를 우선한다 — URL 의 base 가
    // 스타일시트 자신이라 형제가 그 URL 의 대상이고, node_modules 해석은 형제가 없을 때의
    // 폴백이다. 폴백이 살아 있다는 것은 바로 아래 테스트가 지킨다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/package.json", .data = "{\"name\":\"imgpkg\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/pic.png", .data = "PKG" });

    // 동명의 형제 디렉토리 — 이게 이겨야 한다.
    try tmp.dir.createDir(std.testing.io, "imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imgpkg/pic.png", .data = "SIBLING" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "imgpkg/pic.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") == null);

    // `url(./imgpkg/pic.png)` 와 **같은 파일**이어야 한다 — 이게 #4604 의 본질이다.
    const dotted = try cache.resolve(std.testing.io, dir_path, "./imgpkg/pic.png", .css_url);
    try std.testing.expectEqualStrings(resolved.?.file.path, dotted.?.file.path);

    // 대조군 — `.static_import` 는 진짜 모듈 지정자라 **패키지**로 가야 한다.
    // 이게 없으면 "모든 kind 에서 형제 우선" 으로 바꿔도 위 단언이 전부 통과한다.
    const as_module = try cache.resolve(std.testing.io, dir_path, "imgpkg/pic.png", .static_import);
    try std.testing.expect(as_module != null);
    try std.testing.expect(std.mem.indexOf(u8, as_module.?.file.path, "node_modules") != null);
}

test "#4604 resolve: alias 대상이 bare 여도 동명 형제가 alias 를 가리지 않는다" {
    // 형제 프로브가 **alias 치환 후** 철자로 돌면 alias 대상 패키지가 동명 형제 디렉토리에
    // 가려진다. `--alias:x=somepkg` 는 사용자가 그 패키지를 강제한 것이라 파일 존재 여부로
    // 뒤집히면 안 된다. (alias 대상이 절대경로면 이 분기를 안 타므로 bare 대상이 핵심.)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/package.json", .data = "{\"name\":\"imgpkg\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/pic.png", .data = "PKG" });
    // alias 대상과 동명인 형제 디렉토리.
    try tmp.dir.createDir(std.testing.io, "imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imgpkg/pic.png", .data = "SIBLING" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const aliases = [_]@import("resolver.zig").AliasEntry{
        .{ .from = "alias-name", .to = "imgpkg" }, // 대상이 **bare**
    };
    var cache = ResolveCache.init(std.testing.allocator, .{ .alias = &aliases });
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "alias-name/pic.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") != null);

    // 대조군 — alias 가 안 걸리는 이름은 형제가 이긴다 (alias 분기가 형제 우선을 통째로
    // 꺼 버린 게 아님을 보인다).
    const plain = try cache.resolve(std.testing.io, dir_path, "imgpkg/pic.png", .css_url);
    try std.testing.expect(plain != null);
    try std.testing.expect(std.mem.indexOf(u8, plain.?.file.path, "node_modules") == null);
}

test "#4604 resolve: --fallback 대상은 URL 의미론으로 해석되지 않는다" {
    // `url_relative` 는 Resolver 인스턴스 상태라, `applyFallback` 이 수행하는 **재진입**
    // resolve 에서 끄지 않으면 fallback 대상까지 형제 우선으로 해석된다. 대상은 사용자가
    // 옵션에 쓴 평범한 모듈 지정자지 URL 상대 참조가 아니다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/package.json", .data = "{\"name\":\"imgpkg\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/pic.png", .data = "PKG" });
    // fallback 대상과 동명인 형제 디렉토리 — 재진입 resolve 가 URL 의미론이면 이게 이긴다.
    try tmp.dir.createDir(std.testing.io, "imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "imgpkg/pic.png", .data = "SIBLING" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // `logo.png` 는 형제로도 패키지로도 없으므로 fallback 이 걸린다.
    const fallbacks = [_]@import("resolver.zig").FallbackEntry{
        .{ .from = "logo.png", .to = "imgpkg/pic.png" },
    };
    var cache = ResolveCache.init(std.testing.allocator, .{ .fallback = &fallbacks });
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "logo.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") != null);

    // 대조군 — 같은 지정자를 **직접** URL 참조로 쓰면 형제가 이긴다. 이게 없으면
    // "형제 우선 자체가 꺼졌다" 는 회귀에서도 위 단언이 통과한다.
    const direct = try cache.resolve(std.testing.io, dir_path, "imgpkg/pic.png", .css_url);
    try std.testing.expect(direct != null);
    try std.testing.expect(std.mem.indexOf(u8, direct.?.file.path, "node_modules") == null);
}

test "#4604 resolve: alias 대상이 없으면 마지막 수단으로 원문 형제를 본다" {
    // alias 가 걸리면 exact 형제 프로브는 건너뛰지만, 아무것도 해석되지 않으면 마지막에
    // 원문 철자로 전체 경로 사다리를 태운다 (main 의 `"./" ++ spec` 재시도와 같은 자리).
    // 없애 봤더니 alias 대상이 깨진 프로젝트에서 지금까지 방출되던 자산이 조용히 사라졌다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logo.png", .data = "SIBLING" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const aliases = [_]@import("resolver.zig").AliasEntry{
        .{ .from = "logo.png", .to = "no-such-package-anywhere" },
    };
    var cache = ResolveCache.init(std.testing.allocator, .{ .alias = &aliases });
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "logo.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?.file.path, "logo.png"));

    // 대조군 — URL kind 가 아니면 이 마지막 수단은 없다 (진짜 모듈 import 는 alias 실패 = 실패).
    try std.testing.expectError(
        error.ModuleNotFound,
        cache.resolve(std.testing.io, dir_path, "logo.png", .static_import),
    );
}

test "#4604 resolve: bare 지정자도 마지막 수단에서 확장자 추론이 살아 있다" {
    // exact 프로브만 남기고 마지막 수단을 지웠더니, `new URL("worker.js")` + 디스크의
    // `worker.ts`(moduleResolution NodeNext 가 요구하는 철자)가 **해석 자체를 못 해**
    // warning 만 남기고 원문이 방출됐다 → 404. 추론은 아무것도 해석 안 됐을 때만 돈다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "worker.ts", .data = "self.postMessage(1);" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "worker.js", .worker);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?.file.path, "worker.ts"));

    // 대조군 — 추론이 **패키지보다 앞서면** 안 된다. 아래 테스트가 그걸 지킨다.
}

test "#4604 resolve: 형제 우선은 정확한 파일명일 때만 (확장자 추론 없음)" {
    // 프로브가 일반 경로 해석 사다리를 타면 확장자 붙이기·`.js`→`.ts` 매핑·RN @2x·디렉토리
    // 인덱스까지 걸려, **동명 형제가 없는데도** 패키지가 조용히 가려진다. URL 은 실제
    // 파일명을 그대로 쓰므로 추론이 애초에 URL 의미론에 없다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/wpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/wpkg/package.json", .data = "{\"name\":\"wpkg\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/wpkg/w.js", .data = "PKG" });
    // 로컬엔 `w.ts` 만 있다 — `w.js` 라는 이름의 형제는 **없다**.
    try tmp.dir.createDir(std.testing.io, "wpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wpkg/w.ts", .data = "LOCAL_TS" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "wpkg/w.js", .worker);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") != null);

    // 대조군 — 정확히 그 이름의 형제가 있으면 이긴다. `ResolveCache` 는 무효화 API 가
    // 없으므로(같은 키 = 위 결과 재사용) **새 캐시**로 재본다.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wpkg/w.js", .data = "LOCAL_JS" });
    var fresh = ResolveCache.init(std.testing.allocator, .{});
    defer fresh.deinit();
    const exact = try fresh.resolve(std.testing.io, dir_path, "wpkg/w.js", .worker);
    try std.testing.expect(exact != null);
    try std.testing.expect(std.mem.indexOf(u8, exact.?.file.path, "node_modules") == null);
}

test "#4604 resolve: --fallback:K=false 로 끈 지정자는 형제가 있어도 비활성 유지" {
    // 형제 우선이 `applyFallback` 보다 앞서므로, 그냥 두면 사용자가 일부러 뺀 자산이
    // 형제로 해석돼 번들·방출된다. `=false` 는 "이 이름은 쓰지 마라" 는 명시적 지시다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logo.png", .data = "SIBLING" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const fallbacks = [_]@import("resolver.zig").FallbackEntry{
        .{ .from = "logo.png", .to = null },
    };
    var cache = ResolveCache.init(std.testing.allocator, .{ .fallback = &fallbacks });
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "logo.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.? == .disabled); // 빈 모듈 — 자산으로 방출되지 않는다

    // 대조군 — 끄지 않은 이름은 형제로 정상 해석된다.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.png", .data = "SIBLING2" });
    const kept = try cache.resolve(std.testing.io, dir_path, "keep.png", .css_url);
    try std.testing.expect(kept != null);
    try std.testing.expect(kept.? == .file);
}

test "#4604 resolve: block_list 에 막힌 형제가 패키지 폴백을 막지 않는다" {
    // 형제 히트를 그대로 돌려주면 상위 `resolve()` 가 차단 후 ModuleNotFound 로 끝내 버려,
    // 원래 이기던 node_modules 대상까지 도달하지 못한다 → 원문 방출 404.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/legacy", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/legacy/package.json", .data = "{\"name\":\"legacy\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/legacy/logo.png", .data = "PKG" });
    try tmp.dir.createDir(std.testing.io, "legacy", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "legacy/logo.png", .data = "BLOCKED" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const blocked = try std.fmt.allocPrint(std.testing.allocator, "{s}/legacy/.*", .{dir_path});
    defer std.testing.allocator.free(blocked);

    const block_list = [_][]const u8{blocked};
    var cache = ResolveCache.init(std.testing.allocator, .{ .block_list = &block_list });
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "legacy/logo.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") != null);
}

test "#4604 resolve: 패키지 browser 필드 remap 이 동명 형제에 가리지 않는다" {
    // `url_relative` 판정은 원문 철자로 하는데 resolver 에는 remap 된 철자를 넘긴다.
    // 켠 채로 넘기면 browser 필드가 가리킨 대상이 **패키지 내부의 동명 디렉토리**에 가려져
    // 엉뚱한 자산이 방출된다. browser 필드도 `--alias` 와 같은 명시적 재작성이다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/pkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "node_modules/pkg/package.json",
        .data = "{\"name\":\"pkg\",\"browser\":{\"icons/a.png\":\"shared-icons/a.png\"}}",
    });
    try tmp.dir.createDir(std.testing.io, "node_modules/pkg/icons", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/pkg/icons/a.png", .data = "ORIG" });
    // remap 대상과 동명인 **패키지 내부** 디렉토리 — 형제 우선이 켜져 있으면 이게 이긴다.
    try tmp.dir.createDir(std.testing.io, "node_modules/pkg/shared-icons", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/pkg/shared-icons/a.png", .data = "STRAY" });
    // browser 필드가 실제로 가리키는 패키지.
    try tmp.dir.createDir(std.testing.io, "node_modules/shared-icons", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/shared-icons/package.json", .data = "{\"name\":\"shared-icons\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/shared-icons/a.png", .data = "REMAP_TARGET" });

    const pkg_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "node_modules/pkg", std.testing.allocator);
    defer std.testing.allocator.free(pkg_dir);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, pkg_dir, "icons/a.png", .css_url);
    try std.testing.expect(resolved != null);
    // remap 대상 패키지여야 한다 — `node_modules/pkg/shared-icons/` 가 아니라.
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules/shared-icons") != null);
}

test "#4604 resolve: 형제가 없으면 bare css url() 은 여전히 패키지로 폴백한다" {
    // 위 테스트의 비공허성 대조군 — 형제 우선이 패키지 해석 자체를 없애는 것으로 번지면
    // 안 된다 (esbuild·rspack 도 이 경우 패키지 자산을 쓴다).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "node_modules", .default_dir);
    try tmp.dir.createDir(std.testing.io, "node_modules/imgpkg", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/package.json", .data = "{\"name\":\"imgpkg\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/imgpkg/pic.png", .data = "PKG" });
    // 형제 디렉토리는 두지 않는다 — 이 픽스처의 위험 조건이 "형제 부재" 다.

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "imgpkg/pic.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") != null);
}

test "#4485 resolve: 패키지가 없으면 bare 가 형제 경로로 폴백된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // node_modules 없이 형제 디렉토리만 존재 → 폴백이 이걸 찾아야 한다.
    try tmp.dir.createDir(std.testing.io, "img", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "img/logo.png", .data = "PNG" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "img/logo.png", .css_url);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.?.file.path, "node_modules") == null);
    try std.testing.expect(std.mem.endsWith(u8, resolved.?.file.path, "logo.png"));
}

test "#4485 isExternal: --packages=external 의 bare 규칙은 css_url 에 그대로 적용 (알려진 한계)" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .packages_external = true });
    defer cache.deinit();

    // worker 는 #4483 이 이 규칙에서 뺐다.
    try std.testing.expect(!cache.isExternalForKind("logo.png", .worker));
    // css_url 은 **일부러 빼지 않는다** — #4604 에서 빼 봤더니 `--packages=external` 로 의존성을
    // 미해석 상태로 두려는 라이브러리 빌드가 의존성 자산 사본을 dist 에 싣게 됐다(실측).
    // 재작성이 필요하면 `url(./logo.png)` 로 쓴다.
    try std.testing.expect(cache.isExternalForKind("logo.png", .css_url));
    // 명시적 상대 경로는 이 규칙과 무관 (is_path).
    try std.testing.expect(!cache.isExternalForKind("./logo.png", .css_url));
}

test "#4485 isExternal: --platform=node 의 Node builtin 자동 external 은 css_url/worker 에 적용 안 함" {
    var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();

    // 일반 import 는 그대로 — `import "path"` / `import "util/types"` 는 builtin.
    try std.testing.expect(cache.isExternalForKind("path", .static_import));
    try std.testing.expect(cache.isExternalForKind("util/types", .static_import));

    // CSS `url()` / worker 의 지정자는 URL 상대 참조지 모듈 지정자가 아니다.
    // isNodeBuiltin 이 sub-path 도 builtin 으로 치기 때문에(`util/types`), 이 규칙을 그대로
    // 적용하면 `url(path/logo.png)` 같은 **자산 디렉토리**가 통째로 external 로 빠져
    // 원문 방출(= 404) 된다. `url()` 이 `require("path")` 를 가리킬 리는 없다.
    try std.testing.expect(!cache.isExternalForKind("path/logo.png", .css_url));
    try std.testing.expect(!cache.isExternalForKind("url/x.png", .css_url));
    try std.testing.expect(!cache.isExternalForKind("path/w.js", .worker));

    // `node:` 프리픽스는 kind 와 무관하게 항상 external (기존 동작 유지).
    try std.testing.expect(cache.isExternalForKind("node:path", .css_url));
}

test "#4485 resolve: --platform=node 에서 builtin 이름과 겹치는 자산 디렉토리도 해석된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `path/` 는 Node builtin 이름과 겹치는 **자산 디렉토리** 다.
    try tmp.dir.createDir(std.testing.io, "path", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "path/logo.png", .data = "PNG" });

    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .{ .platform = .node });
    defer cache.deinit();

    const resolved = try cache.resolve(std.testing.io, dir_path, "path/logo.png", .css_url);
    try std.testing.expect(resolved != null); // external(null) 이 아니라 실제 파일
    try std.testing.expect(std.mem.endsWith(u8, resolved.?.file.path, "logo.png"));

    // 일반 import 는 여전히 builtin → external (null).
    try std.testing.expect(try cache.resolve(std.testing.io, dir_path, "path", .static_import) == null);
}
