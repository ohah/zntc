//! #1603 Phase 1b 회귀 테스트: `import { M } from './idx'` 형태로 들여온 심볼이
//! `export * as M from './src'` (re_export_namespace)를 겨냥할 때, 소비자 모듈의
//! `M.foo` 접근을 추적해 source 모듈의 미사용 export를 tree-shake 하는지 검증.

const std = @import("std");
const testing = std.testing;
const Bundler = @import("../bundler.zig").Bundler;
const BundleResult = @import("../bundler.zig").BundleResult;
const resolve_cache_mod = @import("../resolve_cache.zig");
const writeFile = @import("../test_helpers.zig").writeFile;

/// 테스트 전용 랩퍼: BundleResult + arena (linker 관련 로컬 할당 수명 보장).
const Bundled = struct {
    arena: std.heap.ArenaAllocator,
    result: BundleResult,

    fn code(self: *const Bundled) []const u8 {
        return self.result.output;
    }

    fn deinit(self: *Bundled) void {
        self.result.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }
};

fn bundleEntry(backing: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !Bundled {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const dp = try tmp.dir.realpathAlloc(arena_alloc, ".");
    const entry = try std.fs.path.resolve(arena_alloc, &.{ dp, entry_name });

    var cache = resolve_cache_mod.ResolveCache.init(backing, .{});
    defer cache.deinit();

    var bundler = Bundler.initWithResolveCache(backing, .{
        .entry_points = &.{entry},
        .format = .iife,
        .scope_hoist = true,
        .tree_shaking = true,
    }, &cache);
    defer bundler.deinit();

    const result = try bundler.bundle();
    return .{ .arena = arena, .result = result };
}

test "virtual ns (#1603): import { M } from re_export_namespace — 미사용 member prune" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\export const foo = 1;
        \\export const bar = 2;
        \\export const baz = 3;
    );
    try writeFile(tmp.dir, "idx.ts", "export * as M from './a.ts';");
    try writeFile(tmp.dir, "entry.ts",
        \\import { M } from './idx.ts';
        \\console.log(M.foo);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    const code = r.code();

    // 사용된 foo는 남아야 함
    try testing.expect(std.mem.indexOf(u8, code, "const foo = 1") != null);
    // 미사용 bar/baz는 tree-shake되어야 함
    try testing.expect(std.mem.indexOf(u8, code, "const bar = 2") == null);
    try testing.expect(std.mem.indexOf(u8, code, "const baz = 3") == null);
}

test "virtual ns (#1603): 여러 member 접근 시 모두 보존" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\export const alpha = 1;
        \\export const beta = 2;
        \\export const gamma = 3;
        \\export const delta = 4;
    );
    try writeFile(tmp.dir, "idx.ts", "export * as NS from './a.ts';");
    try writeFile(tmp.dir, "entry.ts",
        \\import { NS } from './idx.ts';
        \\console.log(NS.alpha, NS.gamma);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    const code = r.code();

    try testing.expect(std.mem.indexOf(u8, code, "const alpha = 1") != null);
    try testing.expect(std.mem.indexOf(u8, code, "const gamma = 3") != null);
    try testing.expect(std.mem.indexOf(u8, code, "const beta = 2") == null);
    try testing.expect(std.mem.indexOf(u8, code, "const delta = 4") == null);
}

test "virtual ns (#1603): opaque 사용 시 fallback — 전체 유지" {
    // NS가 값으로 전달(console.log(NS))되면 opaque로 판정 → fallback으로 전체 export 유지
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\export const x = 10;
        \\export const y = 20;
    );
    try writeFile(tmp.dir, "idx.ts", "export * as NS from './a.ts';");
    try writeFile(tmp.dir, "entry.ts",
        \\import { NS } from './idx.ts';
        \\console.log(NS);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    const code = r.code();

    // opaque → 둘 다 유지 (fallback 동작)
    try testing.expect(std.mem.indexOf(u8, code, "const x = 10") != null);
    try testing.expect(std.mem.indexOf(u8, code, "const y = 20") != null);
}

test "virtual ns (#1603): 여러 소비자가 모두 precise하면 union만 유지" {
    // 두 entry에서 서로 다른 member 접근 — union = [a, c]만 유지, b 제거
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src.ts",
        \\export const a = 1;
        \\export const b = 2;
        \\export const c = 3;
    );
    try writeFile(tmp.dir, "idx.ts", "export * as NS from './src.ts';");
    try writeFile(tmp.dir, "helper.ts",
        \\import { NS } from './idx.ts';
        \\export const useA = () => NS.a;
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { NS } from './idx.ts';
        \\import { useA } from './helper.ts';
        \\console.log(useA(), NS.c);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    const code = r.code();

    try testing.expect(std.mem.indexOf(u8, code, "const a = 1") != null);
    try testing.expect(std.mem.indexOf(u8, code, "const c = 3") != null);
    try testing.expect(std.mem.indexOf(u8, code, "const b = 2") == null);
}
