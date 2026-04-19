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

// ============================================================
// #1567 follow-up: dead-scope gating for namespace member access
//
// svelte 5.55 client runtime 번들에서 관찰된 패턴.
//   errors.js       - 30+개의 `export function *_err()` (순수 함수, 선언만)
//   index-client.js - `import * as e from './errors.js';
//                      export function onMount() { e.lifecycle_outside_component(...); }
//                      export function mount() { ... /* e 접근 없음 */ }`
//   entry           - `import { mount }` (onMount은 import 안 함)
//
// 기대(esbuild 동작): `onMount`가 entry 체인에서 도달 불가 → dead.
// 따라서 body 안의 `e.lifecycle_outside_component` 접근도 dead →
// `lifecycle_outside_component` export도 제거 가능.
//
// 현재 ZTS 동작: namespace member access 분석이 "dead function 안의 access인지"를
// 구분하지 않아, `lifecycle_outside_component`가 accessed로 마킹 → errors.js의
// 해당 export 보존. svelte 번들 기준 약 16-20개 에러 함수 불필요 보존.
// ============================================================

test "virtual ns (#1626): dead function body 내 namespace access는 target을 보존하면 안 됨" {
    // #1626 fix: linker.analyzeNamespaceAccess가 각 member access의 owning stmt를 기록하고,
    // tree_shaker.followImport가 dispatch_stmt 기준으로 per-prop seed를 gating한다.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "errors.ts",
        \\export function dead_err() { return "dead-err-marker"; }
        \\export function live_err() { return "live-err-marker"; }
    );
    try writeFile(tmp.dir, "lib.ts",
        \\import * as e from './errors.ts';
        \\export function unused_lifecycle() { return e.dead_err(); }
        \\export function used_api() { return e.live_err(); }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_api } from './lib.ts';
        \\console.log(used_api());
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    const code = r.code();

    // live 경로: 항상 유지되어야 함
    try testing.expect(std.mem.indexOf(u8, code, "live-err-marker") != null);

    // dead 경로: `unused_lifecycle`가 entry에서 도달 불가 → body의 `e.dead_err` 접근도 dead.
    try testing.expect(std.mem.indexOf(u8, code, "unused_lifecycle") == null);
    try testing.expect(std.mem.indexOf(u8, code, "dead-err-marker") == null);
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
