const std = @import("std");
const tree_shaker_mod = @import("tree_shaker.zig");
const TreeShaker = tree_shaker_mod.TreeShaker;
const ALL_EXPORTS_SENTINEL = tree_shaker_mod.ALL_EXPORTS_SENTINEL;
const Linker = @import("linker.zig").Linker;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const resolve_cache_mod = @import("resolve_cache.zig");
const writeFile = @import("test_helpers.zig").writeFile;

const TestResult = struct {
    shaker: TreeShaker,
    linker: Linker,
    /// heap-allocated ModuleGraph (Linker/TreeShaker.graph 안정화 목적, #1779 PR #2).
    graph: *ModuleGraph,
    cache: resolve_cache_mod.ResolveCache,

    fn deinit(self: *TestResult) void {
        self.shaker.deinit();
        self.linker.deinit();
        self.graph.deinit();
        std.testing.allocator.destroy(self.graph);
        self.cache.deinit();
    }

    /// 모듈 경로 접미사로 인덱스 조회. 못 찾으면 null.
    fn findModule(self: *const TestResult, suffix: []const u8) ?u32 {
        for (0..self.graph.moduleCount()) |i| {
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
            if (std.mem.endsWith(u8, m.path, suffix)) return @intCast(i);
        }
        return null;
    }
};

/// side_effects=false 설정 없이 빌드+분석.
fn buildAndShake(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    return buildAndShakeWithOpts(allocator, tmp, entry_name, &.{});
}

/// side_effects=false로 설정할 모듈 접미사 목록을 받는 테스트 헬퍼.
fn buildAndShakeWithOpts(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    entry_name: []const u8,
    no_side_effects: []const []const u8,
) !TestResult {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    const graph = try allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(allocator, &cache);
    try graph.build(&.{entry});

    for (0..graph.moduleCount()) |i| {
        const m = graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        for (no_side_effects) |suffix| {
            if (std.mem.endsWith(u8, m.path, suffix)) {
                m.side_effects = false;
                break;
            }
        }
    }

    var linker = Linker.init(allocator, graph, .esm);
    try linker.link();
    linker.populateImportSymbols();

    var shaker = try TreeShaker.init(allocator, graph, &linker);
    try shaker.analyze(&.{entry});

    return .{ .shaker = shaker, .linker = linker, .graph = graph, .cache = cache };
}

test "tree-shaking: unused module with side_effects=true is included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    // 두 모듈 모두 포함 (side_effects=true 기본)
    try std.testing.expect(r.shaker.isIncluded(0)); // a.ts (entry)
    try std.testing.expect(r.shaker.isIncluded(1)); // b.ts (imported + side_effects)
}

test "tree-shaking: unused module with side_effects=false is excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42; import './c';");
    try writeFile(tmp.dir, "c.ts", "export const unused = 'no one uses me';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "a.ts", &.{"c.ts"});
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(0));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("b.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("c.ts").?));
}

// --- 테스트 3: 진입점의 모든 export는 사용됨으로 마킹 ---
test "tree-shaking: entry point exports are all marked as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const a = 1; export const b = 2; export function c() {}");

    var r = try buildAndShake(std.testing.allocator, &tmp, "index.ts");
    defer r.deinit();

    // 진입점 모듈의 export가 전부 사용됨으로 마킹
    try std.testing.expect(r.shaker.isExportUsed(0, "a"));
    try std.testing.expect(r.shaker.isExportUsed(0, "b"));
    try std.testing.expect(r.shaker.isExportUsed(0, "c"));
}

test "tree-shaking: only imported exports are marked as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { used } from './b'; console.log(used);");
    try writeFile(tmp.dir, "b.ts", "export const used = 1; export const unused = 2;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    const b = r.findModule("b.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(b, "used"));
    try std.testing.expect(!r.shaker.isExportUsed(b, "unused"));
}

test "tree-shaking: re-export chain marks canonical export as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("c.ts").?, "x"));
}

test "tree-shaking: default import marks default export as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import greet from './b'; greet();");
    try writeFile(tmp.dir, "b.ts", "export default function greet() { return 'hi'; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("b.ts").?, "default"));
}

test "tree-shaking: side_effects=true module always included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './polyfill'; const x = 1;");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.foo = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("polyfill.ts").?));
}

// --- 테스트 8: 순환 참조 모듈 포함 ---
test "tree-shaking: circular dependency modules included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; export const a = x + 1;");
    try writeFile(tmp.dir, "b.ts", "import { a } from './a'; export const x = 1;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    // 순환 참조: 양쪽 모두 포함
    try std.testing.expect(r.shaker.isIncluded(0));
    try std.testing.expect(r.shaker.isIncluded(1));
}

// --- 테스트 9: 포함된 모듈의 의존성 전파 ---
test "tree-shaking: included module's dependencies are propagated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a → b → c 체인. a가 b를 import하고, b가 c를 import.
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "import { y } from './c'; export const x = y + 1;");
    try writeFile(tmp.dir, "c.ts", "export const y = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    // a, b, c 모두 포함
    for (0..r.graph.moduleCount()) |i| {
        try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
    }
}

// --- 테스트 10: 빈 그래프 ---
test "tree-shaking: empty module graph" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    linker.populateImportSymbols();

    var shaker = try TreeShaker.init(std.testing.allocator, &graph, &linker);
    defer shaker.deinit();
    try shaker.analyze(&.{});

    // 빈 그래프에서 아무것도 포함 안 됨
    try std.testing.expect(!shaker.isIncluded(0));
}

test "tree-shaking: diamond dependency — shared module included once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; import { y } from './c'; console.log(x, y);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './d'; export const x = shared + 1;");
    try writeFile(tmp.dir, "c.ts", "import { shared } from './d'; export const y = shared + 2;");
    try writeFile(tmp.dir, "d.ts", "export const shared = 100;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "a.ts");
    defer r.deinit();

    for (0..r.graph.moduleCount()) |i| {
        try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
    }
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("d.ts").?, "shared"));
}

test "tree-shaking: side_effects=false but used export — module included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { util } from './b'; console.log(util);");
    try writeFile(tmp.dir, "b.ts", "export const util = 'useful'; export const unused = 'dead';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "a.ts", &.{"b.ts"});
    defer r.deinit();

    const b = r.findModule("b.ts").?;
    try std.testing.expect(r.shaker.isIncluded(b));
    try std.testing.expect(r.shaker.isExportUsed(b, "util"));
    try std.testing.expect(!r.shaker.isExportUsed(b, "unused"));
}

// ============================================================
// esbuild 참고 테스트 (snapshots_dce.txt, bundler_dce_test.go)
// ============================================================

test "esbuild: sideEffects=false keeps module when named import used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from './pkg'; console.log(foo);");
    try writeFile(tmp.dir, "pkg.ts", "export const foo = 123; console.log('pkg side effect');");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"pkg.ts"});
    defer r.deinit();

    const pkg = r.findModule("pkg.ts").?;
    try std.testing.expect(r.shaker.isIncluded(pkg));
    try std.testing.expect(r.shaker.isExportUsed(pkg, "foo"));
}

test "esbuild: sideEffects=false removes module when import unused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from './pkg'; console.log('unused import');");
    try writeFile(tmp.dir, "pkg.ts", "export const foo = 123; console.log('hello');");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"pkg.ts"});
    defer r.deinit();

    try std.testing.expect(!r.shaker.isIncluded(r.findModule("pkg.ts").?));
}

test "esbuild: sideEffects=false removes side-effect-only import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './pkg'; console.log('entry');");
    try writeFile(tmp.dir, "pkg.ts", "console.log('should be removed');");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"pkg.ts"});
    defer r.deinit();

    try std.testing.expect(!r.shaker.isIncluded(r.findModule("pkg.ts").?));
}

// --- esbuild: namespace import (import * as ns) → 모든 export 사용됨 ---
// TestPackageJsonSideEffectsFalseKeepStarImportES6 참고
test "esbuild: namespace import marks all exports as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './lib'; console.log(ns);");
    try writeFile(tmp.dir, "lib.ts", "export const a = 1; export const b = 2; export const c = 3;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    var lib_idx: u32 = 0;
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "lib.ts")) {
            lib_idx = @intCast(i);
            break;
        }
    }

    // namespace import → 모든 export 사용됨
    try std.testing.expect(r.shaker.isIncluded(lib_idx));
    try std.testing.expect(r.shaker.isExportUsed(lib_idx, "a"));
    try std.testing.expect(r.shaker.isExportUsed(lib_idx, "b"));
    try std.testing.expect(r.shaker.isExportUsed(lib_idx, "c"));
}

// ============================================================
// Rolldown 참고 테스트 (tree-shake/ fixtures)
// ============================================================

// --- rolldown: re-export 체인에서 side_effects 추적 ---
// issue2864: re-export chain preserves side effects
test "rolldown: re-export chain preserves side-effect module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry → common → sideeffect → foo
    // sideeffect.ts has globalThis mutation (side effect)
    try writeFile(tmp.dir, "entry.ts", "import { foo } from './common'; console.log(foo);");
    try writeFile(tmp.dir, "common.ts", "export { foo } from './sideeffect';");
    try writeFile(tmp.dir, "sideeffect.ts", "export { foo } from './foo'; globalThis.aa = true;");
    try writeFile(tmp.dir, "foo.ts", "export const foo = 'hello';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // 모든 모듈 포함 (side_effects=true 기본이므로)
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "sideeffect.ts")) {
            try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
        }
        if (std.mem.endsWith(u8, m.path, "foo.ts")) {
            try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
            try std.testing.expect(r.shaker.isExportUsed(@intCast(i), "foo"));
        }
    }
}

// --- rolldown: module-side-effects function → 특정 모듈만 제거 ---
// module-side-effects-function: a.mjs(false) removed, b.js(true) kept
test "rolldown: sideEffects=false module removed, true kept" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts", "import './alpha'; import './beta'; console.log('main');");
    try writeFile(tmp.dir, "alpha.ts", "console.log('alpha - should be removed');");
    try writeFile(tmp.dir, "beta.ts", "console.log('beta - should be kept');");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "main.ts", &.{"alpha.ts"});
    defer r.deinit();

    try std.testing.expect(!r.shaker.isIncluded(r.findModule("alpha.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("beta.ts").?));
}

// --- rolldown: barrel file에서 사용 안 하는 re-export 모듈 추적 ---
test "rolldown: barrel file — only used re-exports tracked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // index.ts가 barrel file (여러 모듈 re-export)
    try writeFile(tmp.dir, "entry.ts", "import { a } from './index'; console.log(a);");
    try writeFile(tmp.dir, "index.ts", "export { a } from './mod-a'; export { b } from './mod-b';");
    try writeFile(tmp.dir, "mod-a.ts", "export const a = 'used';");
    try writeFile(tmp.dir, "mod-b.ts", "export const b = 'unused';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // mod-a의 a는 사용됨
    var mod_a_idx: u32 = 0;
    var mod_b_idx: u32 = 0;
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "mod-a.ts")) mod_a_idx = @intCast(i);
        if (std.mem.endsWith(u8, m.path, "mod-b.ts")) mod_b_idx = @intCast(i);
    }
    try std.testing.expect(r.shaker.isExportUsed(mod_a_idx, "a"));
    // mod-b의 b는 사용되지 않음
    try std.testing.expect(!r.shaker.isExportUsed(mod_b_idx, "b"));
}

// --- rolldown: export * from + 부분 사용 ---
test "rolldown: export * — only used names tracked through star" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './barrel'; console.log(x);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './lib';");
    try writeFile(tmp.dir, "lib.ts", "export const x = 1; export const y = 2; export const z = 3;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    var lib_idx: u32 = 0;
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "lib.ts")) {
            lib_idx = @intCast(i);
            break;
        }
    }
    // export *를 통해 x만 사용됨
    try std.testing.expect(r.shaker.isExportUsed(lib_idx, "x"));
    try std.testing.expect(!r.shaker.isExportUsed(lib_idx, "y"));
    try std.testing.expect(!r.shaker.isExportUsed(lib_idx, "z"));
}

// ============================================================
// Rollup 참고 테스트 (test/form/samples/)
// ============================================================

// --- rollup: deconflict-tree-shaken — tree-shaking 후 이름 충돌 ---
test "rollup: deconflict after tree-shaking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈에서 같은 이름 x 사용. 하나는 사용됨, 하나는 미사용 export.
    try writeFile(tmp.dir, "entry.ts", "import { x } from './used'; console.log(x);");
    try writeFile(tmp.dir, "used.ts", "export const x = 'from used';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    var used_idx: u32 = 0;
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "used.ts")) {
            used_idx = @intCast(i);
            break;
        }
    }
    try std.testing.expect(r.shaker.isIncluded(used_idx));
    try std.testing.expect(r.shaker.isExportUsed(used_idx, "x"));
}

// --- rollup: class-constructor-side-effect ---
// 클래스 인스턴스화는 side effect (constructor 실행)
test "rollup: module with class instantiation has side effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './effects';");
    try writeFile(tmp.dir, "effects.ts",
        \\class Effect { constructor() { console.log('side effect'); } }
        \\new Effect();
    );

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // effects.ts는 side_effects=true (기본) → 포함
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "effects.ts")) {
            try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
        }
    }
}

// --- rollup: 다이아몬드 + side_effects=false 리프 ---
test "rollup: diamond with sideEffects=false leaf — leaf included if used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; import { y } from './c'; console.log(x, y);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './leaf'; export const x = shared + 1;");
    try writeFile(tmp.dir, "c.ts", "export const y = 99;");
    try writeFile(tmp.dir, "leaf.ts", "export const shared = 42; export const dead = 'unused';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "a.ts", &.{"leaf.ts"});
    defer r.deinit();

    const leaf = r.findModule("leaf.ts").?;
    try std.testing.expect(r.shaker.isIncluded(leaf));
    try std.testing.expect(r.shaker.isExportUsed(leaf, "shared"));
    try std.testing.expect(!r.shaker.isExportUsed(leaf, "dead"));
}

test "rollup: entry exports all marked, dependency only used ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './dep'; export const result = x;");
    try writeFile(tmp.dir, "dep.ts", "export const x = 1; export const y = 2; export const z = 3;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(0, "result"));
    const dep = r.findModule("dep.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(dep, "x"));
    try std.testing.expect(!r.shaker.isExportUsed(dep, "y"));
    try std.testing.expect(!r.shaker.isExportUsed(dep, "z"));
}

test "rollup: unused import from sideEffects=false module excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { unused } from './pure-lib'; console.log('entry only');");
    try writeFile(tmp.dir, "pure-lib.ts", "export function unused() { return 42; }");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"pure-lib.ts"});
    defer r.deinit();

    try std.testing.expect(!r.shaker.isIncluded(r.findModule("pure-lib.ts").?));
}

// ============================================================
// 복합 시나리오 (여러 번들러 패턴 조합)
// ============================================================

test "complex: deep re-export chain with sideEffects=false intermediaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './barrel1'; console.log(val);");
    try writeFile(tmp.dir, "barrel1.ts", "export { val } from './barrel2';");
    try writeFile(tmp.dir, "barrel2.ts", "export { val } from './barrel3';");
    try writeFile(tmp.dir, "barrel3.ts", "export { val } from './leaf';");
    try writeFile(tmp.dir, "leaf.ts", "export const val = 'deep';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "barrel1.ts", "barrel2.ts", "barrel3.ts" });
    defer r.deinit();

    const leaf = r.findModule("leaf.ts").?;
    try std.testing.expect(r.shaker.isIncluded(leaf));
    try std.testing.expect(r.shaker.isExportUsed(leaf, "val"));
}

test "complex: multiple entry points share dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry1.ts", "import { shared } from './shared'; console.log(shared);");
    try writeFile(tmp.dir, "entry2.ts", "import { other } from './shared'; console.log(other);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1; export const other = 2; export const dead = 3;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry1.ts");
    defer r.deinit();

    const s = r.findModule("shared.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(s, "shared"));
    try std.testing.expect(!r.shaker.isExportUsed(s, "other"));
    try std.testing.expect(!r.shaker.isExportUsed(s, "dead"));
}

test "complex: multiple export * sources — partial usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a, c } from './barrel'; console.log(a, c);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './mod-a'; export * from './mod-b';");
    try writeFile(tmp.dir, "mod-a.ts", "export const a = 1; export const b = 2;");
    try writeFile(tmp.dir, "mod-b.ts", "export const c = 3; export const d = 4;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const ma = r.findModule("mod-a.ts").?;
    const mb = r.findModule("mod-b.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(ma, "a"));
    try std.testing.expect(!r.shaker.isExportUsed(ma, "b"));
    try std.testing.expect(r.shaker.isExportUsed(mb, "c"));
    try std.testing.expect(!r.shaker.isExportUsed(mb, "d"));
}

test "complex: circular dependency with sideEffects=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './ca'; console.log(a);");
    try writeFile(tmp.dir, "ca.ts", "import { b } from './cb'; export const a = b + 1;");
    try writeFile(tmp.dir, "cb.ts", "import { a } from './ca'; export const b = 10;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "ca.ts", "cb.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("ca.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("cb.ts").?));
}

test "complex: long chain — orphans excluded (sideEffects=false)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './m1'; import './m4'; import './m5'; console.log(val);");
    try writeFile(tmp.dir, "m1.ts", "export { val } from './m2';");
    try writeFile(tmp.dir, "m2.ts", "export { val } from './m3';");
    try writeFile(tmp.dir, "m3.ts", "export const val = 'target';");
    try writeFile(tmp.dir, "m4.ts", "export const orphan4 = 'dead';");
    try writeFile(tmp.dir, "m5.ts", "export const orphan5 = 'dead';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "m4.ts", "m5.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("m3.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("m4.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("m5.ts").?));
}

test "complex: type-only import does not mark export as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from './lib'; console.log(value);");
    try writeFile(tmp.dir, "lib.ts", "export const value = 1; export interface Type { x: number; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "value"));
}

test "complex: re-export default through barrel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './barrel'; console.log(foo);");
    try writeFile(tmp.dir, "barrel.ts", "export { default } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default function impl() { return 42; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const impl = r.findModule("impl.ts").?;
    try std.testing.expect(r.shaker.isIncluded(impl));
    try std.testing.expect(r.shaker.isExportUsed(impl, "default"));
}

// ============================================================
// reference_count 기반 미사용 import 감지 테스트
// (esbuild/rollup/rolldown이 지원하지만 ZTS가 아직 못 하는 것)
// ============================================================

// --- esbuild: import 후 사용 안 한 named import + sideEffects=false → 미사용 export ---
// import { foo } 했지만 foo를 코드에서 한 번도 안 씀 → foo의 reference_count == 0
// → 해당 export를 "사용됨"으로 마킹하면 안 됨
test "refcount: unused named import not marked as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from './lib'; console.log('no foo usage');");
    try writeFile(tmp.dir, "lib.ts", "export const foo = 42; export const bar = 99;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(!r.shaker.isExportUsed(lib, "foo"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "bar"));
}

test "refcount: partial usage — only actually used import marked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { used, notUsed } from './lib'; console.log(used);");
    try writeFile(tmp.dir, "lib.ts", "export const used = 1; export const notUsed = 2;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(lib, "used"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "notUsed"));
}

test "refcount: unused default import not marked as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './lib'; console.log('no foo');");
    try writeFile(tmp.dir, "lib.ts", "export default function foo() { return 42; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(!r.shaker.isExportUsed(r.findModule("lib.ts").?, "default"));
}

test "refcount: barrel sideEffects=false — unused re-export source excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './barrel'; console.log(a);");
    try writeFile(tmp.dir, "barrel.ts", "export { a } from './src-a'; export { b } from './src-b';");
    try writeFile(tmp.dir, "src-a.ts", "export const a = 'used';");
    try writeFile(tmp.dir, "src-b.ts", "export const b = 'unused';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "barrel.ts", "src-b.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("src-a.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("src-b.ts").?));
}

test "refcount: multiple imports partial use + sideEffects=false excludes module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './active';
        \\import { b } from './dormant';
        \\console.log(a);
    );
    try writeFile(tmp.dir, "active.ts", "export const a = 'yes';");
    try writeFile(tmp.dir, "dormant.ts", "export const b = 'no';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"dormant.ts"});
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("active.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("dormant.ts").?));
}

// ============================================================
// export { x } (from 없이) — import→re-export 패턴
// ============================================================

// import한 심볼을 export { x }로 re-export하는 중간 모듈
// reference_count가 0이어도 export binding이 있으면 체인이 동작해야 함
test "re-export-local: import then export { x } passes through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './mid'; console.log(x);");
    // mid.ts: import한 x를 export { x }로 내보냄 (re-export가 아닌 local export)
    try writeFile(tmp.dir, "mid.ts", "import { x } from './leaf'; export { x };");
    try writeFile(tmp.dir, "leaf.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // entry가 x를 사용 → mid 포함 → leaf 포함
    for (0..r.graph.moduleCount()) |i| {
        const m = r.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
        if (std.mem.endsWith(u8, m.path, "leaf.ts")) {
            try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
        }
        if (std.mem.endsWith(u8, m.path, "mid.ts")) {
            try std.testing.expect(r.shaker.isIncluded(@intCast(i)));
        }
    }
}

// sideEffects=false인 중간 모듈에서 import→export { x }
// x의 reference_count가 0이면 chain이 끊길 수 있음 (잠재적 버그)
test "re-export-local: sideEffects=false mid module — chain still works" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './mid'; console.log(x);");
    try writeFile(tmp.dir, "mid.ts", "import { x } from './leaf'; export { x };");
    try writeFile(tmp.dir, "leaf.ts", "export const x = 42;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "mid.ts", "leaf.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("mid.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("leaf.ts").?));
}

// ============================================================
// 제외된 모듈의 import가 다른 모듈을 오염시키지 않는지 검증
// ============================================================

// --- 핵심: 제외된 모듈의 import는 export 사용으로 카운트하면 안 됨 ---
// entry → dead(미사용, sideEffects=false) → deep(sideEffects=false)
// dead가 제외되면 deep도 제외되어야 함
test "fixpoint: excluded module's imports don't mark exports as used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './alive';
        \\import { orphan } from './dead';
        \\console.log(a);
    );
    try writeFile(tmp.dir, "alive.ts", "export const a = 1;");
    try writeFile(tmp.dir, "dead.ts", "import { x } from './deep'; export const orphan = x;");
    try writeFile(tmp.dir, "deep.ts", "export const x = 99;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "dead.ts", "deep.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("alive.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("dead.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("deep.ts").?));
}

test "fixpoint: transitive unused chain all excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { val } from './chain-a';
        \\const x = 1;
    );
    try writeFile(tmp.dir, "chain-a.ts", "import { b } from './chain-b'; export const val = b;");
    try writeFile(tmp.dir, "chain-b.ts", "import { c } from './chain-c'; export const b = c;");
    try writeFile(tmp.dir, "chain-c.ts", "export const c = 42;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "chain-a.ts", "chain-b.ts", "chain-c.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(0)); // entry
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("chain-a.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("chain-b.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("chain-c.ts").?));
}

test "fixpoint: shared dep included if any live module uses it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './mod-a';
        \\import { b } from './mod-b';
        \\console.log(a);
    );
    try writeFile(tmp.dir, "mod-a.ts", "import { s } from './shared'; export const a = s;");
    try writeFile(tmp.dir, "mod-b.ts", "import { s } from './shared'; export const b = s;");
    try writeFile(tmp.dir, "shared.ts", "export const s = 'shared';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "mod-a.ts", "mod-b.ts", "shared.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("mod-a.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("mod-b.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("shared.ts").?));
}

// ============================================================
// 새 테스트 케이스
// ============================================================

test "new: import used in typeof expression counts as reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Foo } from './lib'; console.log(typeof Foo);");
    try writeFile(tmp.dir, "lib.ts", "export class Foo {}");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "Foo"));
}

test "new: export default class imported as default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import Foo from './cls'; new Foo();");
    try writeFile(tmp.dir, "cls.ts", "export default class Foo { constructor() {} }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("cls.ts").?, "default"));
}

test "new: re-export with rename — import { x }; export { x as y }" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { y } from './rename'; console.log(y);");
    try writeFile(tmp.dir, "rename.ts", "import { x } from './origin'; export { x as y };");
    try writeFile(tmp.dir, "origin.ts", "export const x = 'original';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("origin.ts").?));
}

test "new: sideEffects=false barrel with unused export * source excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './barrel'; console.log(a);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './used-src'; export * from './dead-src';");
    try writeFile(tmp.dir, "used-src.ts", "export const a = 1;");
    try writeFile(tmp.dir, "dead-src.ts", "export const z = 99;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"dead-src.ts"});
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("used-src.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("dead-src.ts").?));
}

test "new: 5-level re-export chain all sideEffects=false — leaf included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { v } from './r1'; console.log(v);");
    try writeFile(tmp.dir, "r1.ts", "export { v } from './r2';");
    try writeFile(tmp.dir, "r2.ts", "export { v } from './r3';");
    try writeFile(tmp.dir, "r3.ts", "export { v } from './r4';");
    try writeFile(tmp.dir, "r4.ts", "export { v } from './r5';");
    try writeFile(tmp.dir, "r5.ts", "export const v = 'leaf';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "r1.ts", "r2.ts", "r3.ts", "r4.ts", "r5.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("r5.ts").?));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("r5.ts").?, "v"));
}

test "new: mixed used and unused imports from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a, b, c } from './lib'; console.log(b);");
    try writeFile(tmp.dir, "lib.ts", "export const a = 1; export const b = 2; export const c = 3;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(!r.shaker.isExportUsed(lib, "a"));
    try std.testing.expect(r.shaker.isExportUsed(lib, "b"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "c"));
}

test "new: import used as function argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './lib'; someFunc(val);");
    try writeFile(tmp.dir, "lib.ts", "export const val = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "val"));
}

test "new: import used in binary expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; const y = x + 1;");
    try writeFile(tmp.dir, "lib.ts", "export const x = 10;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

// ============================================================
// Edge case 추가 테스트
// ============================================================

// import alias: local name과 exported name이 다를 때
test "edge: import { x as y } — alias tracked correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x as y } from './lib'; console.log(y);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // exported name은 "x", local name은 "y". y가 사용됐으므로 x export가 사용됨.
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

// import alias 미사용: alias를 import했지만 사용 안 함
test "edge: import { x as y } unused — not marked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x as y } from './lib'; console.log('no y');");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(!r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

// default + named 동시 import, named만 사용
test "edge: import default and named — only named used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import def, { named } from './lib'; console.log(named);");
    try writeFile(tmp.dir, "lib.ts", "export default 'unused-default'; export const named = 'used';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(!r.shaker.isExportUsed(lib, "default"));
    try std.testing.expect(r.shaker.isExportUsed(lib, "named"));
}

// default + named 동시 import, default만 사용
test "edge: import default and named — only default used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import def, { named } from './lib'; console.log(def);");
    try writeFile(tmp.dir, "lib.ts", "export default 'used-default'; export const named = 'unused';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(lib, "default"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "named"));
}

// expression default export
test "edge: export default expression (not function/class)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import val from './expr'; console.log(val);");
    try writeFile(tmp.dir, "expr.ts", "export default { key: 'value' };");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("expr.ts").?, "default"));
}

// 같은 re-export 문에서 부분 사용: export { a, b } from './lib', a만 사용
test "edge: partial named re-export — only used name tracked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './re'; console.log(a);");
    try writeFile(tmp.dir, "re.ts", "export { a, b } from './source';");
    try writeFile(tmp.dir, "source.ts", "export const a = 1; export const b = 2;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const src = r.findModule("source.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(src, "a"));
    try std.testing.expect(!r.shaker.isExportUsed(src, "b"));
}

// sideEffects=false + export 없는 모듈 (코드만 있음)
test "edge: sideEffects=false module with no exports — excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './pure-side'; console.log('entry');");
    try writeFile(tmp.dir, "pure-side.ts", "console.log('side effect only, no exports');");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"pure-side.ts"});
    defer r.deinit();

    // export 없고 sideEffects=false → 제거
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("pure-side.ts").?));
}

// nested scope에서만 사용: 함수 안에서 import된 심볼 참조
test "edge: import used only inside nested function" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; function foo() { return x; } foo();");
    try writeFile(tmp.dir, "lib.ts", "export const x = 99;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // x는 nested scope에서 참조 → reference_count > 0
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

// export { default as foo } — default를 named로 re-export
test "edge: export { default as foo } from source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from './reexport'; console.log(foo);");
    try writeFile(tmp.dir, "reexport.ts", "export { default as foo } from './source';");
    try writeFile(tmp.dir, "source.ts", "export default function() { return 42; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("source.ts").?));
}

// 3개 모듈 순환 + 전부 sideEffects=false, 진입점에서 하나만 사용
test "edge: 3-module cycle all sideEffects=false — used one pulls in cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './cyc-a'; console.log(a);");
    try writeFile(tmp.dir, "cyc-a.ts", "import { b } from './cyc-b'; export const a = b + 1;");
    try writeFile(tmp.dir, "cyc-b.ts", "import { c } from './cyc-c'; export const b = c + 1;");
    try writeFile(tmp.dir, "cyc-c.ts", "import { a } from './cyc-a'; export const c = 10;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "cyc-a.ts", "cyc-b.ts", "cyc-c.ts" });
    defer r.deinit();

    // a 사용 → cyc-a 포함 → b 사용 → cyc-b 포함 → c 사용 → cyc-c 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("cyc-a.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("cyc-b.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("cyc-c.ts").?));
}

// re-export chain 중간에 side_effects=true: 양 끝은 sideEffects=false
test "edge: re-export chain — middle has side_effects=true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { v } from './start'; console.log(v);");
    try writeFile(tmp.dir, "start.ts", "export { v } from './middle';");
    try writeFile(tmp.dir, "middle.ts", "export { v } from './end'; console.log('side effect');");
    try writeFile(tmp.dir, "end.ts", "export const v = 'final';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "start.ts", "end.ts" });
    defer r.deinit();

    // middle은 side_effects=true(기본) → 항상 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("middle.ts").?));
    // end는 sideEffects=false이지만 v가 사용됨 → 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("end.ts").?));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("end.ts").?, "v"));
}

// import 후 변수에 할당만 하고 그 변수는 미사용
test "edge: import assigned to unused variable — still counts as reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; const y = x;");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // x는 `const y = x`에서 참조됨 → reference_count > 0
    // (y가 미사용인 건 statement-level DCE에서 처리)
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

// 같은 모듈을 여러 파일에서 import하지만 각각 다른 export 사용
test "edge: same module imported by multiple — union of used exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './consumer1'; import { b } from './consumer2'; console.log(a, b);");
    try writeFile(tmp.dir, "consumer1.ts", "import { x } from './shared'; export const a = x;");
    try writeFile(tmp.dir, "consumer2.ts", "import { y } from './shared'; export const b = y;");
    try writeFile(tmp.dir, "shared.ts", "export const x = 1; export const y = 2; export const z = 3;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const s = r.findModule("shared.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(s, "x"));
    try std.testing.expect(r.shaker.isExportUsed(s, "y"));
    try std.testing.expect(!r.shaker.isExportUsed(s, "z"));
}

// ============================================================
// 사용 컨텍스트별 테스트 — import가 다양한 위치에서 참조될 때
// ============================================================

test "usage: import in template literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { name } from './lib'; console.log(`hello ${name}`);");
    try writeFile(tmp.dir, "lib.ts", "export const name = 'world';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "name"));
}

test "usage: import in array literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; const arr = [x, 1, 2];");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

test "usage: import in object property value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './lib'; const obj = { key: val };");
    try writeFile(tmp.dir, "lib.ts", "export const val = 99;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "val"));
}

test "usage: import in ternary condition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { flag } from './lib'; const y = flag ? 1 : 0;");
    try writeFile(tmp.dir, "lib.ts", "export const flag = true;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "flag"));
}

test "usage: import in return statement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; function f() { return x; } f();");
    try writeFile(tmp.dir, "lib.ts", "export const x = 1;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

test "usage: import as computed property key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { key } from './lib'; const obj = { [key]: 1 };");
    try writeFile(tmp.dir, "lib.ts", "export const key = 'dynamic';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "key"));
}

test "usage: import in for-of iterable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { items } from './lib'; for (const x of items) { console.log(x); }");
    try writeFile(tmp.dir, "lib.ts", "export const items = [1, 2, 3];");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "items"));
}

test "usage: import in class field initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './lib'; class Foo { prop = val; }");
    try writeFile(tmp.dir, "lib.ts", "export const val = 'init';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "val"));
}

test "usage: import in default parameter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { def } from './lib'; function f(a = def) { return a; }");
    try writeFile(tmp.dir, "lib.ts", "export const def = 10;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "def"));
}

test "usage: import in logical expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; x && console.log('yes');");
    try writeFile(tmp.dir, "lib.ts", "export const x = true;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

test "usage: import in throw statement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { err } from './lib'; throw err;");
    try writeFile(tmp.dir, "lib.ts", "export const err = new Error('fail');");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "err"));
}

test "usage: import in switch case value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { VAL } from './lib'; switch(1) { case VAL: break; }");
    try writeFile(tmp.dir, "lib.ts", "export const VAL = 1;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "VAL"));
}

test "usage: import as new argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Cls } from './lib'; new Cls();");
    try writeFile(tmp.dir, "lib.ts", "export class Cls {}");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "Cls"));
}

test "usage: import in member expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { obj } from './lib'; console.log(obj.x);");
    try writeFile(tmp.dir, "lib.ts", "export const obj = { x: 1 };");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "obj"));
}

test "usage: import in assignment RHS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; let y; y = x;");
    try writeFile(tmp.dir, "lib.ts", "export const x = 5;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("lib.ts").?, "x"));
}

// ============================================================
// 구조 패턴 테스트 — 모듈 그래프 구조별
// ============================================================

test "structure: wide fan-out — entry imports 6, uses 2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './fa';
        \\import { b } from './fb';
        \\import { c } from './fc';
        \\import { d } from './fd';
        \\import { e } from './fe';
        \\import { f } from './ff';
        \\console.log(b, e);
    );
    try writeFile(tmp.dir, "fa.ts", "export const a = 1;");
    try writeFile(tmp.dir, "fb.ts", "export const b = 2;");
    try writeFile(tmp.dir, "fc.ts", "export const c = 3;");
    try writeFile(tmp.dir, "fd.ts", "export const d = 4;");
    try writeFile(tmp.dir, "fe.ts", "export const e = 5;");
    try writeFile(tmp.dir, "ff.ts", "export const f = 6;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "fa.ts", "fc.ts", "fd.ts", "ff.ts" });
    defer r.deinit();

    // b, e만 사용 → fb, fe 포함. 나머지 sideEffects=false → 제거
    try std.testing.expect(r.shaker.isIncluded(r.findModule("fb.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("fe.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("fa.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("fc.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("fd.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("ff.ts").?));
}

test "structure: entry with no exports — just side effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib'; console.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(0));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("lib.ts").?));
}

test "structure: empty module with no code" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './empty'; console.log('hi');");
    try writeFile(tmp.dir, "empty.ts", "");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // empty.ts는 side_effects=true(기본) → 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("empty.ts").?));
}

test "structure: empty module sideEffects=false excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './empty'; console.log('hi');");
    try writeFile(tmp.dir, "empty.ts", "");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"empty.ts"});
    defer r.deinit();

    try std.testing.expect(!r.shaker.isIncluded(r.findModule("empty.ts").?));
}

test "structure: module imports but uses nothing — sideEffects=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './passthrough'; console.log('entry');");
    try writeFile(tmp.dir, "passthrough.ts", "import { x } from './deep';");
    try writeFile(tmp.dir, "deep.ts", "export const x = 1;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "passthrough.ts", "deep.ts" });
    defer r.deinit();

    // passthrough imports deep but doesn't use or re-export x
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("passthrough.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("deep.ts").?));
}

test "structure: barrel that re-exports and adds own export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { own, ext } from './barrel'; console.log(own, ext);");
    try writeFile(tmp.dir, "barrel.ts", "export { ext } from './external'; export const own = 'mine';");
    try writeFile(tmp.dir, "external.ts", "export const ext = 'theirs';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("barrel.ts").?, "own"));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("external.ts").?, "ext"));
}

test "structure: two imports from same module in separate statements" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a } from './lib'; import { b } from './lib'; console.log(a);");
    try writeFile(tmp.dir, "lib.ts", "export const a = 1; export const b = 2;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(lib, "a"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "b"));
}

test "structure: re-export rename chain A→B→C with renames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { z } from './b-re'; console.log(z);");
    try writeFile(tmp.dir, "b-re.ts", "export { y as z } from './a-re';");
    try writeFile(tmp.dir, "a-re.ts", "export { x as y } from './origin';");
    try writeFile(tmp.dir, "origin.ts", "export const x = 'renamed-twice';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("origin.ts").?));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("origin.ts").?, "x"));
}

test "structure: sideEffects=false module imported by live and dead — still included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './live';
        \\import { b } from './dead';
        \\console.log(a);
    );
    try writeFile(tmp.dir, "live.ts", "import { s } from './util'; export const a = s;");
    try writeFile(tmp.dir, "dead.ts", "import { s } from './util'; export const b = s;");
    try writeFile(tmp.dir, "util.ts", "export const s = 'shared';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "live.ts", "dead.ts", "util.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("live.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("dead.ts").?));
    // util은 live가 사용 → 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("util.ts").?));
}

test "structure: diamond all sideEffects=false — only used paths included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry → left, right. left → leaf (uses it). right → leaf (doesn't use it).
    try writeFile(tmp.dir, "entry.ts", "import { l } from './left'; console.log(l);");
    try writeFile(tmp.dir, "left.ts", "import { v } from './dleaf'; export const l = v;");
    try writeFile(tmp.dir, "right.ts", "import { v } from './dleaf'; export const r = 'unused';");
    try writeFile(tmp.dir, "dleaf.ts", "export const v = 'leaf-val';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "left.ts", "right.ts", "dleaf.ts" });
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("left.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("dleaf.ts").?));
    // right는 entry가 import하지 않으므로 그래프에 없을 수 있음
    // 그래프에 있다면 미사용 → 제거
    if (r.findModule("right.ts")) |ri| {
        try std.testing.expect(!r.shaker.isIncluded(ri));
    }
}

// ============================================================
// 여러 side_effects 조합 테스트
// ============================================================

test "side-effects: three imports — true/false/true mix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './se-true1'; import './se-false'; import './se-true2';");
    try writeFile(tmp.dir, "se-true1.ts", "console.log('side1');");
    try writeFile(tmp.dir, "se-false.ts", "console.log('should remove');");
    try writeFile(tmp.dir, "se-true2.ts", "console.log('side2');");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"se-false.ts"});
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("se-true1.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("se-false.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("se-true2.ts").?));
}

test "side-effects: sideEffects=false circular pair unused from entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry imports cycle but doesn't use any export
    try writeFile(tmp.dir, "entry.ts",
        \\import { p } from './cyp';
        \\import { q } from './cyq';
        \\console.log('no p or q');
    );
    try writeFile(tmp.dir, "cyp.ts", "import { q } from './cyq'; export const p = q;");
    try writeFile(tmp.dir, "cyq.ts", "import { p } from './cyp'; export const q = 1;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "cyp.ts", "cyq.ts" });
    defer r.deinit();

    // p, q 모두 미사용 + sideEffects=false → 양쪽 다 제거
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("cyp.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("cyq.ts").?));
}

test "side-effects: deep chain all sideEffects=false — all excluded when unused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './d1'; console.log('ignore x');");
    try writeFile(tmp.dir, "d1.ts", "import { y } from './d2'; export const x = y;");
    try writeFile(tmp.dir, "d2.ts", "import { z } from './d3'; export const y = z;");
    try writeFile(tmp.dir, "d3.ts", "export const z = 'deep';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{ "d1.ts", "d2.ts", "d3.ts" });
    defer r.deinit();

    // x imported but never referenced in code → all excluded
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("d1.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("d2.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("d3.ts").?));
}

// ============================================================
// export * 심화 테스트
// ============================================================

test "export-star: chained export * from → partial usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { deep } from './layer1'; console.log(deep);");
    try writeFile(tmp.dir, "layer1.ts", "export * from './layer2';");
    try writeFile(tmp.dir, "layer2.ts", "export * from './source';");
    try writeFile(tmp.dir, "source.ts", "export const deep = 1; export const shallow = 2;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const src = r.findModule("source.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(src, "deep"));
    try std.testing.expect(!r.shaker.isExportUsed(src, "shallow"));
}

test "export-star: two sources with no overlap — selective usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x, z } from './hub'; console.log(x, z);");
    try writeFile(tmp.dir, "hub.ts", "export * from './src-x'; export * from './src-z';");
    try writeFile(tmp.dir, "src-x.ts", "export const x = 1; export const y = 2;");
    try writeFile(tmp.dir, "src-z.ts", "export const z = 3; export const w = 4;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("src-x.ts").?, "x"));
    try std.testing.expect(!r.shaker.isExportUsed(r.findModule("src-x.ts").?, "y"));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("src-z.ts").?, "z"));
    try std.testing.expect(!r.shaker.isExportUsed(r.findModule("src-z.ts").?, "w"));
}

// ============================================================
// TypeScript 특화 테스트
// ============================================================

test "typescript: interface-only module — no value exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './func'; console.log(greet());");
    try writeFile(tmp.dir, "func.ts", "export function greet() { return 'hi'; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("func.ts").?, "greet"));
}

test "typescript: enum import used in member expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Color.Red는 static_member_expression → left(Color)가 identifier_reference로 순회됨
    try writeFile(tmp.dir, "entry.ts", "import { Color } from './enums'; console.log(Color.Red);");
    try writeFile(tmp.dir, "enums.ts", "export enum Color { Red, Green, Blue }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // enum export가 binding_scanner에서 어떻게 추출되는지에 따라 다름.
    // Color가 export_bindings에 있으면 isExportUsed가 true.
    // 없으면 module이 side_effects=true(기본)이라 포함은 됨.
    try std.testing.expect(r.shaker.isIncluded(r.findModule("enums.ts").?));
}

test "typescript: enum import used directly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // member expression 아닌 직접 사용
    try writeFile(tmp.dir, "entry.ts", "import { Color } from './enums'; console.log(Color);");
    try writeFile(tmp.dir, "enums.ts", "export enum Color { Red, Green, Blue }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("enums.ts").?));
}

test "typescript: abstract class import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Base } from './base'; class Impl extends Base {} new Impl();");
    try writeFile(tmp.dir, "base.ts", "export abstract class Base { abstract run(): void; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("base.ts").?, "Base"));
}

// ============================================================
// export default 변형 테스트
// ============================================================

test "default: export default number literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import val from './num'; console.log(val);");
    try writeFile(tmp.dir, "num.ts", "export default 42;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("num.ts").?, "default"));
}

test "default: export default arrow function" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import fn from './arrow'; fn();");
    try writeFile(tmp.dir, "arrow.ts", "export default () => 'hello';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("arrow.ts").?, "default"));
}

test "default: export default array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import arr from './arr'; console.log(arr.length);");
    try writeFile(tmp.dir, "arr.ts", "export default [1, 2, 3];");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("arr.ts").?, "default"));
}

test "default: unused default + used named from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { named } from './mixed'; console.log(named);");
    try writeFile(tmp.dir, "mixed.ts", "export default 'unused'; export const named = 'used';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const m = r.findModule("mixed.ts").?;
    try std.testing.expect(!r.shaker.isExportUsed(m, "default"));
    try std.testing.expect(r.shaker.isExportUsed(m, "named"));
}

// ============================================================
// 레퍼런스 번들러 추가 패턴 (rollup/rolldown/esbuild)
// ============================================================

// --- rollup: export * 이름 충돌 — 두 소스에서 같은 이름 export ---
// rollup/test/form/samples/export-all-multiple 참고
test "ref: export * name collision — both sources have same export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './barrel'; console.log(x);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './src1'; export * from './src2';");
    try writeFile(tmp.dir, "src1.ts", "export const x = 'from-src1'; export const only1 = 1;");
    try writeFile(tmp.dir, "src2.ts", "export const x = 'from-src2'; export const only2 = 2;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // x가 사용됨 — 어느 소스에서 왔든 하나는 마킹
    // (충돌 해결은 linker의 역할, tree-shaker는 사용 여부만 추적)
    const src1 = r.findModule("src1.ts");
    const src2 = r.findModule("src2.ts");
    const x_used_in_src1 = if (src1) |i| r.shaker.isExportUsed(i, "x") else false;
    const x_used_in_src2 = if (src2) |i| r.shaker.isExportUsed(i, "x") else false;
    try std.testing.expect(x_used_in_src1 or x_used_in_src2);
    // only1, only2는 사용되지 않음
    if (src1) |i| try std.testing.expect(!r.shaker.isExportUsed(i, "only1"));
    if (src2) |i| try std.testing.expect(!r.shaker.isExportUsed(i, "only2"));
}

// --- rollup: 순수 re-export 모듈 (자체 코드 없음) + sideEffects=false ---
// 모듈이 오직 re-export만 하고 자체 코드가 없으면, sideEffects=false일 때 제거 가능
test "ref: pure re-export module with no own code — sideEffects=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './pure-reexport'; console.log(x);");
    try writeFile(tmp.dir, "pure-reexport.ts", "export { x } from './real';");
    try writeFile(tmp.dir, "real.ts", "export const x = 'value';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"pure-reexport.ts"});
    defer r.deinit();

    // pure-reexport.ts는 sideEffects=false + re-export만 → 자체는 제거 가능하지만
    // linker가 x를 resolve하여 real.ts의 x를 canonical로 찾음
    try std.testing.expect(r.shaker.isIncluded(r.findModule("real.ts").?));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("real.ts").?, "x"));
}

// --- rolldown: namespace import + side effect 중간 모듈 ---
// issue2864-2: import * as ns 체인에서 중간 side effect 보존
test "ref: namespace import chain with side-effect intermediary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './wrapper'; console.log(val);");
    try writeFile(tmp.dir, "wrapper.ts", "export { val } from './side-mod';");
    try writeFile(tmp.dir, "side-mod.ts", "export { val } from './leaf-val'; globalThis.patched = true;");
    try writeFile(tmp.dir, "leaf-val.ts", "export const val = 'hello';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    // side-mod.ts는 side_effects=true(기본) + globalThis 변경 → 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("side-mod.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("leaf-val.ts").?));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("leaf-val.ts").?, "val"));
}

// --- rollup: re-export alias 3단계 체인 (x→y→z→w) ---
// rollup/test/form/samples/re-export-aliasing 참고
test "ref: triple rename re-export chain — x as y as z as w" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { w } from './c-alias'; console.log(w);");
    try writeFile(tmp.dir, "c-alias.ts", "export { z as w } from './b-alias';");
    try writeFile(tmp.dir, "b-alias.ts", "export { y as z } from './a-alias';");
    try writeFile(tmp.dir, "a-alias.ts", "export { x as y } from './orig';");
    try writeFile(tmp.dir, "orig.ts", "export const x = 'original';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("orig.ts").?));
    try std.testing.expect(r.shaker.isExportUsed(r.findModule("orig.ts").?, "x"));
}

// --- rollup: export * from internal + external 혼합 ---
test "ref: export * from internal mixed with external" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { intFn } from './hub'; console.log(intFn());");
    try writeFile(tmp.dir, "hub.ts", "export * from './internal';");
    try writeFile(tmp.dir, "internal.ts", "export function intFn() { return 42; }");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("internal.ts").?, "intFn"));
}

// --- esbuild: sideEffects=false + 깊은 import 체인 + 중간만 사용 ---
// A→B→C→D→E, entry가 C의 export만 사용, 나머지 sideEffects=false
test "ref: deep chain — middle module used, ends excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { c } from './dc';
        \\import { e } from './de';
        \\console.log(c);
    );
    try writeFile(tmp.dir, "dc.ts", "export const c = 'used';");
    try writeFile(tmp.dir, "de.ts", "export const e = 'unused';");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"de.ts"});
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("dc.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("de.ts").?));
}

// --- rolldown: export * from 체인 + sideEffects=false 중간 ---
// entry → barrel(sideEffects=false) → export * from lib
// barrel 자체는 re-export만 하고, lib의 export 중 일부만 사용
test "ref: export * barrel sideEffects=false — only used exports from source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { alpha } from './star-barrel'; console.log(alpha);");
    try writeFile(tmp.dir, "star-barrel.ts", "export * from './star-source';");
    try writeFile(tmp.dir, "star-source.ts", "export const alpha = 1; export const beta = 2; export const gamma = 3;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"star-barrel.ts"});
    defer r.deinit();

    const src = r.findModule("star-source.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(src, "alpha"));
    try std.testing.expect(!r.shaker.isExportUsed(src, "beta"));
    try std.testing.expect(!r.shaker.isExportUsed(src, "gamma"));
}

// --- esbuild: 모듈이 export만 있고 import가 없는 독립 모듈 ---
test "ref: standalone module with only exports — no imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { PI } from './constants'; console.log(PI);");
    try writeFile(tmp.dir, "constants.ts", "export const PI = 3.14; export const E = 2.71; export const TAU = 6.28;");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const c = r.findModule("constants.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(c, "PI"));
    try std.testing.expect(!r.shaker.isExportUsed(c, "E"));
    try std.testing.expect(!r.shaker.isExportUsed(c, "TAU"));
}

// --- rollup: re-export 중간 모듈이 자체 export도 가짐 ---
// 중간 모듈이 re-export + 자체 export. entry는 re-export된 것만 사용.
test "ref: intermediary with own exports + re-exports — only re-exported used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { remote } from './middle'; console.log(remote);");
    try writeFile(tmp.dir, "middle.ts", "export { remote } from './remote-src'; export const local = 'not-used';");
    try writeFile(tmp.dir, "remote-src.ts", "export const remote = 'from-remote';");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    try std.testing.expect(r.shaker.isExportUsed(r.findModule("remote-src.ts").?, "remote"));
    // middle의 자체 export는 사용되지 않음
    try std.testing.expect(!r.shaker.isExportUsed(r.findModule("middle.ts").?, "local"));
}

// --- rolldown: export * from + 사용 안 하는 소스 모듈 전체 제거 ---
test "ref: export * source completely unused + sideEffects=false — excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './reexp'; console.log(x);");
    try writeFile(tmp.dir, "reexp.ts", "export { x } from './needed'; export * from './unneeded';");
    try writeFile(tmp.dir, "needed.ts", "export const x = 1;");
    try writeFile(tmp.dir, "unneeded.ts", "export const y = 2; export const z = 3;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"unneeded.ts"});
    defer r.deinit();

    try std.testing.expect(r.shaker.isIncluded(r.findModule("needed.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("unneeded.ts").?));
}

// --- esbuild: 10개 모듈 wide fan-out, 전부 sideEffects=false, 3개만 사용 ---
test "ref: 10-module fan-out all sideEffects=false — only 3 used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './w1';
        \\import { b } from './w2';
        \\import { c } from './w3';
        \\import { d } from './w4';
        \\import { e } from './w5';
        \\import { f } from './w6';
        \\import { g } from './w7';
        \\import { h } from './w8';
        \\import { i } from './w9';
        \\import { j } from './w10';
        \\console.log(c, f, i);
    );
    try writeFile(tmp.dir, "w1.ts", "export const a = 1;");
    try writeFile(tmp.dir, "w2.ts", "export const b = 2;");
    try writeFile(tmp.dir, "w3.ts", "export const c = 3;");
    try writeFile(tmp.dir, "w4.ts", "export const d = 4;");
    try writeFile(tmp.dir, "w5.ts", "export const e = 5;");
    try writeFile(tmp.dir, "w6.ts", "export const f = 6;");
    try writeFile(tmp.dir, "w7.ts", "export const g = 7;");
    try writeFile(tmp.dir, "w8.ts", "export const h = 8;");
    try writeFile(tmp.dir, "w9.ts", "export const i = 9;");
    try writeFile(tmp.dir, "w10.ts", "export const j = 10;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{
        "w1.ts", "w2.ts", "w3.ts", "w4.ts", "w5.ts",
        "w6.ts", "w7.ts", "w8.ts", "w9.ts", "w10.ts",
    });
    defer r.deinit();

    // c(w3), f(w6), i(w9)만 사용
    try std.testing.expect(r.shaker.isIncluded(r.findModule("w3.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("w6.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("w9.ts").?));
    // 나머지 7개 제거
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w1.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w2.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w4.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w5.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w7.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w8.ts").?));
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("w10.ts").?));
}

// lodash-es 패턴: barrel re-export + sideEffects=false + 전이적 의존성
// processModuleImports가 새 모듈 포함 시 fixpoint 루프 계속해야 함
test "fixpoint: sideEffects=false barrel re-export — transitive deps included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // entry → barrel (re-export) → used → sym → root → freeGlobal
    try writeFile(tmp.dir, "entry.ts", "import { used } from './barrel'; console.log(used);");
    try writeFile(tmp.dir, "barrel.ts",
        \\export { default as used } from './used';
        \\export { default as unused } from './unused';
    );
    try writeFile(tmp.dir, "used.ts", "import sym from './sym'; var used = sym; export default used;");
    try writeFile(tmp.dir, "sym.ts", "import root from './root'; var sym = root.Symbol; export default sym;");
    try writeFile(tmp.dir, "root.ts", "import fg from './freeGlobal'; var root = fg || 42; export default root;");
    try writeFile(tmp.dir, "freeGlobal.ts", "var freeGlobal = typeof globalThis; export default freeGlobal;");
    try writeFile(tmp.dir, "unused.ts", "export default function unused() { return 99; }");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{
        "barrel.ts", "used.ts", "sym.ts", "root.ts", "freeGlobal.ts", "unused.ts",
    });
    defer r.deinit();

    // 전이적 의존성 모두 포함
    try std.testing.expect(r.shaker.isIncluded(r.findModule("used.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("sym.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("root.ts").?));
    try std.testing.expect(r.shaker.isIncluded(r.findModule("freeGlobal.ts").?));
    // unused 제거
    try std.testing.expect(!r.shaker.isIncluded(r.findModule("unused.ts").?));
}

// ============================================================
// #1558 Phase 5 불변식 회귀 가드
// ============================================================
//
// reference_count 기반 필터가 제거된 후 tree_shaker가 지켜야 하는 동작들:
//   1. entry의 미사용 import는 lib을 include시키지 않는다(lib sideEffects=false).
//   2. entry의 모든 top-level statement는 live — 순수 const 선언도 보존.
//   3. `import * as X; X.a()`는 X.a만 seed, 나머지 export는 dead로 판정.
//   4. entry의 dead 분기(dead function/block) 안의 import는 상위로 전파되지 않는다.
//   5. live branch에서 참조되는 모듈-내 private helper는 dead 오판되지 않는다.
//
// 과거 Phase 5 시도에서 seedOpaqueModule의 isImportBindingUsed 필터 삭제로
// entry의 모든 import가 무조건 seed되던 회귀가 있었음(#1562).

test "#1558 Phase 5: entry의 미사용 import는 sideEffects=false 모듈을 포함시키지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from './lib'; console.log('no foo use');");
    try writeFile(tmp.dir, "lib.ts", "export const foo = 42; export const bar = 99;");

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"lib.ts"});
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    // seedOpaqueModule이 live 필터 없이 동작하면 이 assertion이 깨진다.
    try std.testing.expect(!r.shaker.isIncluded(lib));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "foo"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "bar"));
}

test "#1558 Phase 5: entry의 순수 top-level const는 reachable — DCE 제거 금지" {
    // entry는 번들 진입점 — tree-shake 대상이 아니므로 모든 top-level stmt가 live.
    // crossModuleBFS의 entry seed 블록이 export만 seed하면 순수 선언이 사라짐(#1562 회귀).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const a = 1; const b = 2; console.log(a, b);");

    var r = try buildAndShake(std.testing.allocator, &tmp, "entry.ts");
    defer r.deinit();

    const entry = r.findModule("entry.ts").?;
    const infos = r.shaker.getModuleStmtInfos(entry) orelse return error.NoStmtInfo;
    // entry의 모든 stmt가 reachable이어야 — 최소 3개(const a, const b, console.log)
    try std.testing.expect(infos.stmts.len >= 3);
    for (0..infos.stmts.len) |si| {
        try std.testing.expect(r.shaker.isStmtReachable(entry, @intCast(si)));
    }
}

test "#1558 Phase 5: namespace import — 사용된 prop만 seed, 나머지 dead" {
    // #1559 되돌림 이후 동작: `import * as X; X.a()`는 X.a만 used,
    // X.b, X.c는 dead(sideEffects=false 일 때).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as X from './mod';
        \\console.log(X.a(1));
    );
    try writeFile(tmp.dir, "mod.ts",
        \\export function a(n) { return n + 1; }
        \\export function b(n) { return n + 2; }
        \\export function c(n) { return n + 3; }
    );

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"mod.ts"});
    defer r.deinit();

    const mod = r.findModule("mod.ts").?;
    // 모듈은 포함되지만 used 집합은 "a"만 (ALL_EXPORTS_SENTINEL은 마킹 안됨)
    try std.testing.expect(r.shaker.isIncluded(mod));
    try std.testing.expect(r.shaker.isExportUsed(mod, "a"));
    try std.testing.expect(!r.shaker.isExportUsed(mod, "b"));
    try std.testing.expect(!r.shaker.isExportUsed(mod, "c"));
    // #1559 시절엔 sentinel을 무조건 마킹했지만 Phase 4에서 되돌림.
    try std.testing.expect(!r.shaker.isExportUsed(mod, ALL_EXPORTS_SENTINEL));
}

test "#1558 Phase 5: namespace entry — 특정 prop만 쓰면 나머지 전체 dead (valibot 축소)" {
    // valibot 시나리오 축소: entry가 `import * as v from 'lib'; v.a(...)`만.
    // Phase 4/5 이전엔 'lib' 전체가 live로 오판되어 142KB 누수 — Phase 5로 정밀 판정.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as v from './lib';
        \\const r = v.object({ x: 1 });
        \\console.log(r);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function object(o) { return o; }
        \\export function string() { return 'string'; }
        \\export function number() { return 'number'; }
        \\export function array() { return 'array'; }
    );

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"lib.ts"});
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(r.shaker.isExportUsed(lib, "object"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "string"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "number"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "array"));
}

test "#1558 Phase 5: non-entry 모듈의 dead export 안 import는 상위 전파하지 않는다" {
    // barrel의 `unused_export`는 entry에서 사용 안 됨 — 그 안 runtime 참조도
    // live로 마킹되면 runtime 모듈이 따라오는 누수 발생(#1551 svelte 시나리오).
    // Phase 3+4 live_mod_idx 경로가 barrel의 dead stmt 안 import를 배제.
    //
    // (entry 모듈 내 dead function body의 import 전파 차단은 function-level DCE
    //  영역 — Phase 5 범위가 아니며 entry는 tree-shake 대상이 아니므로 보수적으로
    //  모든 top-level stmt가 live 유지.)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { used } from './barrel'; console.log(used());");
    try writeFile(tmp.dir, "barrel.ts",
        \\import { marker } from './runtime';
        \\export function used() { return 'ok'; }
        \\export function unused_export() { return marker; }
    );
    try writeFile(tmp.dir, "runtime.ts", "export const marker = 'RUNTIME';");

    var r = try buildAndShakeWithOpts(
        std.testing.allocator,
        &tmp,
        "entry.ts",
        &.{ "barrel.ts", "runtime.ts" },
    );
    defer r.deinit();

    const runtime = r.findModule("runtime.ts").?;
    try std.testing.expect(!r.shaker.isIncluded(runtime));
    try std.testing.expect(!r.shaker.isExportUsed(runtime, "marker"));
}

test "#1558 Phase 5: live export가 내부 private helper를 참조하면 dead 오판 없음 (hashFragment)" {
    // effect 라이브러리의 hashFragment 회귀 시나리오 축소: used export가
    // 모듈-내 private helper를 호출하면 helper도 live로 유지되어야.
    // enqueue의 ensureSymToIbForModule + 재귀 BFS의 symbol 추적이 보장.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { publicApi } from './lib'; console.log(publicApi());");
    try writeFile(tmp.dir, "lib.ts",
        \\function privateHelper() { return 42; }
        \\export function publicApi() { return privateHelper(); }
        \\export function unusedApi() { return 'other'; }
    );

    var r = try buildAndShakeWithOpts(std.testing.allocator, &tmp, "entry.ts", &.{"lib.ts"});
    defer r.deinit();

    const lib = r.findModule("lib.ts").?;
    try std.testing.expect(r.shaker.isIncluded(lib));
    try std.testing.expect(r.shaker.isExportUsed(lib, "publicApi"));
    try std.testing.expect(!r.shaker.isExportUsed(lib, "unusedApi"));

    // privateHelper는 export는 아니지만 lib 모듈 내 선언이 reachable이어야
    // linker가 dangling reference 없이 번들 가능.
    const lib_mod = r.graph.getModule(ModuleIndex.fromUsize(lib)).?;
    const infos = r.shaker.getModuleStmtInfos(lib) orelse return error.NoStmtInfo;
    const sem = lib_mod.semantic orelse return error.NoSemantic;
    const helper_sym = sem.scope_maps[0].get("privateHelper") orelse return error.NoSym;
    const helper_stmt = infos.declaredStmtBySymbol(@intCast(helper_sym)) orelse return error.NoDeclStmt;
    try std.testing.expect(r.shaker.isStmtReachable(lib, helper_stmt));
}

test "#1558 Phase 5: partial used + live export — 사용 import 경로만 전파" {
    // barrel.live는 lib_A 사용, barrel.dead는 lib_B 사용. entry가 barrel.live만 호출.
    // → lib_A included + A_used마킹, lib_B excluded.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { live } from './barrel'; console.log(live());");
    try writeFile(tmp.dir, "barrel.ts",
        \\import { a } from './lib_a';
        \\import { b } from './lib_b';
        \\export function live() { return a(); }
        \\export function dead() { return b(); }
    );
    try writeFile(tmp.dir, "lib_a.ts", "export function a() { return 'A'; }");
    try writeFile(tmp.dir, "lib_b.ts", "export function b() { return 'B'; }");

    var r = try buildAndShakeWithOpts(
        std.testing.allocator,
        &tmp,
        "entry.ts",
        &.{ "barrel.ts", "lib_a.ts", "lib_b.ts" },
    );
    defer r.deinit();

    const lib_a = r.findModule("lib_a.ts").?;
    const lib_b = r.findModule("lib_b.ts").?;
    try std.testing.expect(r.shaker.isIncluded(lib_a));
    try std.testing.expect(r.shaker.isExportUsed(lib_a, "a"));
    try std.testing.expect(!r.shaker.isIncluded(lib_b));
    try std.testing.expect(!r.shaker.isExportUsed(lib_b, "b"));
}

// TODO: 자동 순수 판별 테스트는 기능 활성화 시 아래 주석 해제
// isModulePure 활성화 PR에서 이 테스트들을 복원하고 기존 테스트도 업데이트 필요
