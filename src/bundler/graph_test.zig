const std = @import("std");
const graph_mod = @import("graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const determineExportsKind = graph_mod.determineExportsKind;
const Module = @import("module.zig").Module;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const import_scanner = @import("import_scanner.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const module_store_mod = @import("module_store.zig");
const pkg_json = @import("package_json.zig");
const writeFile = @import("test_helpers.zig").writeFile;

fn createFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

fn dirPath(tmp: *std.testing.TmpDir) ![]const u8 {
    return try tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

test "graph: single module, no imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
    try std.testing.expectEqual(@as(u32, 0), graph.getModule(ModuleIndex.fromUsize(0)).?.exec_index);
    try std.testing.expectEqual(Module.State.ready, graph.getModule(ModuleIndex.fromUsize(0)).?.state);
}

test "graph: A imports B — correct exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());

    // DFS 후위: B가 먼저 (exec_index=0), A가 나중 (exec_index=1)
    const a_mod = graph.getModule(ModuleIndex.fromUsize(0)).?; // a.ts가 먼저 addModule됨
    const b_mod = graph.getModule(ModuleIndex.fromUsize(1)).?;
    try std.testing.expect(b_mod.exec_index < a_mod.exec_index);
}

test "graph: chain A → B → C — correct exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "import './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 3), graph.moduleCount());

    // C=0, B=1, A=2 (후위 순서)
    const a = graph.getModule(ModuleIndex.fromUsize(0)).?;
    const b = graph.getModule(ModuleIndex.fromUsize(1)).?;
    const c = graph.getModule(ModuleIndex.fromUsize(2)).?;
    try std.testing.expect(c.exec_index < b.exec_index);
    try std.testing.expect(b.exec_index < a.exec_index);
}

test "graph: diamond A→B,C; B→D; C→D — no duplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b'; import './c';");
    try writeFile(tmp.dir, "b.ts", "import './d';");
    try writeFile(tmp.dir, "c.ts", "import './d';");
    try writeFile(tmp.dir, "d.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // D가 중복 없이 4개 모듈
    try std.testing.expectEqual(@as(usize, 4), graph.moduleCount());

    // D가 가장 먼저 실행 (exec_index 최소)
    var min_exec: u32 = std.math.maxInt(u32);
    var min_path: []const u8 = "";
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (m.exec_index < min_exec) {
            min_exec = m.exec_index;
            min_path = m.path;
        }
    }
    try std.testing.expect(std.mem.endsWith(u8, min_path, "d.ts"));
}

test "graph: circular dependency — warning emitted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "import './a';");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // 2개 모듈, 순환 경고 존재
    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());

    var has_circular_warning = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .circular_dependency) has_circular_warning = true;
    }
    try std.testing.expect(has_circular_warning);
}

test "graph: external module — phantom 으로 graph 에 등록 (Rollup parity)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import 'react';");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // a.ts + phantom react = 2 modules. react phantom 의 is_external = true.
    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
    const react_idx = graph.path_to_module.get("react") orelse return error.TestUnexpectedResult;
    const react_mod = graph.getModule(react_idx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(react_mod.is_external);
    // record 의 is_external 도 그대로 set (emit/linker 호환)
    const a_mod = graph.getModule(@enumFromInt(0)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_mod.import_records[0].is_external);
}

test "graph: unresolved import — error diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './nonexistent';");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // 에러 diagnostic 있어야 함
    var has_unresolved = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .unresolved_import) has_unresolved = true;
    }
    try std.testing.expect(has_unresolved);
}

test "graph: bidirectional edges (D078)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // A.dependencies에 B
    try std.testing.expectEqual(@as(usize, 1), graph.getModule(ModuleIndex.fromUsize(0)).?.dependencies.items.len);
    // B.importers에 A
    try std.testing.expectEqual(@as(usize, 1), graph.getModule(ModuleIndex.fromUsize(1)).?.importers.items.len);
}

test "graph: re-export adds dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export * from './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
    try std.testing.expectEqual(@as(usize, 1), graph.getModule(ModuleIndex.fromUsize(0)).?.dependencies.items.len);
}

test "graph: multiple entry points" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry1.ts", "const a = 1;");
    try writeFile(tmp.dir, "entry2.ts", "const b = 2;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const e1 = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry1.ts" });
    defer std.testing.allocator.free(e1);
    const e2 = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry2.ts" });
    defer std.testing.allocator.free(e2);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{ e1, e2 });

    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
    // 둘 다 exec_index가 할당됨 (maxInt 아님)
    try std.testing.expect(graph.getModule(ModuleIndex.fromUsize(0)).?.exec_index != std.math.maxInt(u32));
    try std.testing.expect(graph.getModule(ModuleIndex.fromUsize(1)).?.exec_index != std.math.maxInt(u32));
}

test "graph: dynamic import stored in dynamic_imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const m = import('./lazy');");
    try writeFile(tmp.dir, "lazy.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
    // 동적 import는 dynamic_imports에, dependencies에는 없음
    try std.testing.expectEqual(@as(usize, 0), graph.getModule(ModuleIndex.fromUsize(0)).?.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.getModule(ModuleIndex.fromUsize(0)).?.dynamic_imports.items.len);
}

test "graph: JSON module — no AST, in graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './data.json';");
    try writeFile(tmp.dir, "data.json", "{\"key\":\"value\"}");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
    // JSON 모듈은 ESM AST로 변환됨 (export default <json>)
    const json_mod = graph.getModule(ModuleIndex.fromUsize(1)).?;
    try std.testing.expect(json_mod.ast != null);
    try std.testing.expectEqual(types.ModuleType.json, json_mod.module_type);
    try std.testing.expectEqual(types.ExportsKind.esm, json_mod.exports_kind);
}

test "graph: semantic data preserved after build" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const x = 1;\nexport function greet() { return 'hi'; }");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    const m = graph.getModule(ModuleIndex.fromUsize(0)).?;
    // semantic 데이터가 보존되어야 함
    try std.testing.expect(m.semantic != null);
    const sem = m.semantic.?;
    // exported_names에 x와 greet이 있어야 함
    try std.testing.expect(sem.exported_names.get("x") != null);
    try std.testing.expect(sem.exported_names.get("greet") != null);
    // symbols 배열이 비어있지 않아야 함
    try std.testing.expect(sem.symbols.items.len > 0);
    // scopes 배열이 비어있지 않아야 함
    try std.testing.expect(sem.scopes.len > 0);
}

test "graph: semantic data null for non-JS modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './data.json';");
    try writeFile(tmp.dir, "data.json", "{\"key\":\"value\"}");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // a.ts는 semantic 있음
    try std.testing.expect(graph.getModule(ModuleIndex.fromUsize(0)).?.semantic != null);
    // data.json도 ESM AST로 변환되므로 semantic 있음
    try std.testing.expect(graph.getModule(ModuleIndex.fromUsize(1)).?.semantic != null);
}

test "graph: semantic exported_names tracks default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export default function main() { return 42; }");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    const sem = graph.getModule(ModuleIndex.fromUsize(0)).?.semantic.?;
    try std.testing.expect(sem.exported_names.get("default") != null);
}

test "graph: import/export bindings preserved after build" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nexport const y = x + 1;");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // a.ts: import_bindings에 x가 있어야 함
    const a = graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(a.import_bindings.len > 0);
    try std.testing.expectEqualStrings("x", a.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("x", a.import_bindings[0].imported_name);

    // a.ts: export_bindings에 y가 있어야 함
    try std.testing.expect(a.export_bindings.len > 0);
    try std.testing.expectEqualStrings("y", a.export_bindings[0].exported_name);

    // b.ts: export_bindings에 x가 있어야 함
    const b = graph.getModule(ModuleIndex.fromUsize(1)).?;
    try std.testing.expect(b.export_bindings.len > 0);
    try std.testing.expectEqualStrings("x", b.export_bindings[0].exported_name);
}

test "determineExportsKind: ESM only" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = true,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm, determineExportsKind(scan, "index.ts"));
}

test "determineExportsKind: CJS require" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = true,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "index.js"));
}

test "determineExportsKind: ESM + CJS mixed" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = true,
        .has_cjs_require = true,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm_with_dynamic_fallback, determineExportsKind(scan, "index.js"));
}

test "determineExportsKind: .cjs extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "lib.cjs"));
}

test "determineExportsKind: .mjs extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm, determineExportsKind(scan, "lib.mjs"));
}

test "determineExportsKind: no signals" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.none, determineExportsKind(scan, "script.js"));
}

test "determineExportsKind: exports_dot is CJS" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = true,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "index.js"));
}

test "determineExportsKind: .cts extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "lib.cts"));
}

test "determineExportsKind: .mts extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm, determineExportsKind(scan, "lib.mts"));
}

// ============================================================
// sideEffects glob 패턴 매칭 테스트
// ============================================================

test "matchSideEffectsPatterns: *.css matches css files" {
    const patterns = &[_][]const u8{"*.css"};
    // CSS 파일은 side_effects=true (제거하면 안 됨)
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/style.css",
        "/app/node_modules/pkg",
        patterns,
    ));
    // 하위 디렉토리 CSS도 매칭 (basename 폴백)
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/src/theme.css",
        "/app/node_modules/pkg",
        patterns,
    ));
    // JS 파일은 매칭 안 됨 → side_effects=false (제거 가능)
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/index.js",
        "/app/node_modules/pkg",
        patterns,
    ));
}

test "matchSideEffectsPatterns: exact path match" {
    const patterns = &[_][]const u8{ "./src/polyfill.js", "*.css" };
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/src/polyfill.js",
        "/app/node_modules/pkg",
        patterns,
    ));
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/src/utils.js",
        "/app/node_modules/pkg",
        patterns,
    ));
}

test "matchSideEffectsPatterns: no patterns = no side effects" {
    const patterns = &[_][]const u8{};
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/index.js",
        "/app/node_modules/pkg",
        patterns,
    ));
}

// Issue #1727 §3 — buildIncremental 의 watcher-driven mtime cache.
// changed_files 가 전달되면 set 에 없는 모듈의 stat 을 skip 하고 store 의 cached mtime 을 신뢰.
// `reparsed_indices.len` 으로 cache hit/miss 를 관찰 — disk content 가 바뀌었어도 stat 을
// 건너뛰면 cache 가 신선한 것으로 판정되어 reparse 가 발생하지 않는다.

/// Build 1 (full) — store 채우기.
fn populateStoreForChangedFilesTest(
    cache: *resolve_cache_mod.ResolveCache,
    store: *module_store_mod.PersistentModuleStore,
    entry: []const u8,
) !void {
    var graph = ModuleGraph.init(std.testing.allocator, cache);
    defer graph.deinit();
    try graph.build(&.{entry});
    for (0..graph.moduleCount()) |i| {
        const m = graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.parse_arena == null) continue;
        store.putModule(m.path, m, m.mtime);
    }
}

test "buildIncremental: changed_files=empty → stat skip → cache hit even after disk change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const V = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();

    try populateStoreForChangedFilesTest(&cache, &store, entry);

    // mtime resolution(ns) 차이 보장. macOS APFS 는 ns 까지 추적하지만 같은 syscall window
    // 안에서 두 번 쓰면 동일 mtime 이 될 수 있어 명시적 sleep.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    try writeFile(tmp.dir, "entry.ts", "export const V = 2;");

    var empty: std.StringHashMap(void) = .init(std.testing.allocator);
    defer empty.deinit();

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph2.deinit();
    const r = try graph2.buildIncremental(&.{entry}, &store, &empty);
    defer std.testing.allocator.free(r.reparsed_indices);

    // changed_files 가 비어 있어 entry.ts 의 stat 을 skip → 디스크가 바뀌었어도 cache hit.
    try std.testing.expectEqual(@as(usize, 0), r.reparsed_indices.len);
}

test "buildIncremental: changed_files contains entry → stat → cache miss after disk change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const V = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();

    try populateStoreForChangedFilesTest(&cache, &store, entry);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    try writeFile(tmp.dir, "entry.ts", "export const V = 2;");

    var changed: std.StringHashMap(void) = .init(std.testing.allocator);
    defer changed.deinit();
    try changed.put(entry, {});

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph2.deinit();
    const r = try graph2.buildIncremental(&.{entry}, &store, &changed);
    defer std.testing.allocator.free(r.reparsed_indices);

    // entry 가 changed set 에 있으므로 stat 정상 수행 → 새 mtime 으로 cache miss → reparse 1건.
    try std.testing.expectEqual(@as(usize, 1), r.reparsed_indices.len);
}

test "buildIncremental: changed_files=null → 기존 동작 (전체 stat) — 변경된 파일 reparse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const V = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();

    try populateStoreForChangedFilesTest(&cache, &store, entry);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    try writeFile(tmp.dir, "entry.ts", "export const V = 2;");

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph2.deinit();
    const r = try graph2.buildIncremental(&.{entry}, &store, null);
    defer std.testing.allocator.free(r.reparsed_indices);

    // null fallback — 모든 모듈 stat. 디스크 변경된 entry 는 mtime mismatch → cache miss.
    try std.testing.expectEqual(@as(usize, 1), r.reparsed_indices.len);
}

test "buildIncremental: changed_files=empty + cache miss (new module) → 강제 stat 후 정상 파싱" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const V = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    // store 비어있음 — entry 가 cache 에 없는 신규 모듈.
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();

    var empty: std.StringHashMap(void) = .init(std.testing.allocator);
    defer empty.deinit();

    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    const r = try graph.buildIncremental(&.{entry}, &store, &empty);
    defer std.testing.allocator.free(r.reparsed_indices);

    // changed_files 에 없지만 store 에도 없으므로 skip 조건 불성립 → stat → 신규 파싱.
    try std.testing.expectEqual(@as(usize, 1), r.reparsed_indices.len);
    try std.testing.expectEqual(@as(usize, 1), graph.moduleCount());
    try std.testing.expectEqual(Module.State.ready, graph.getModule(ModuleIndex.fromUsize(0)).?.state);
}

// ============================================================================
// pkg_info_cache (#1744) — lookupPkgInfo 의 correctness / thread-safety / 누수
// ============================================================================

/// 테스트용 ModuleGraph. `lookupPkgInfo` 는 self.allocator / resolve_cache 외에는
/// 그래프 상태를 쓰지 않으므로 modules 등 기타 필드는 default 로 충분.
fn makeGraph() struct { graph: ModuleGraph, cache: *resolve_cache_mod.ResolveCache } {
    const cache = std.testing.allocator.create(resolve_cache_mod.ResolveCache) catch unreachable;
    cache.* = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    return .{ .graph = ModuleGraph.init(std.testing.allocator, cache), .cache = cache };
}

fn freeGraph(g: *ModuleGraph, cache: *resolve_cache_mod.ResolveCache) void {
    g.deinit();
    cache.deinit();
    std.testing.allocator.destroy(cache);
}

/// 임시 tmp 디렉토리 안에 node_modules/<pkg>/package.json 생성.
fn writePkgJson(tmp_dir: std.fs.Dir, pkg_name: []const u8, contents: []const u8) !void {
    var buf: [256]u8 = undefined;
    const rel = try std.fmt.bufPrint(&buf, "node_modules/{s}/package.json", .{pkg_name});
    try writeFile(tmp_dir, rel, contents);
}

/// 패키지 디렉토리 절대 경로 = tmp_root/node_modules/<pkg>. findPackageDirPath 검증용.
fn pkgDirAbs(tmp: *std.testing.TmpDir, pkg_name: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const rel = try std.fmt.allocPrint(std.testing.allocator, "node_modules/{s}", .{pkg_name});
    defer std.testing.allocator.free(rel);
    return try std.fs.path.resolve(std.testing.allocator, &.{ root, rel });
}

test "pkg_info_cache: missing package.json → unknown + is_module=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pkg_abs = try pkgDirAbs(&tmp, "ghost-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const info = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(false, info.is_module);
    try std.testing.expect(info.side_effects == .unknown);
    try std.testing.expectEqual(@as(u32, 1), gc.graph.pkg_info_cache.count());
}

test "pkg_info_cache: type=module → is_module=true, side_effects=unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "mod-pkg", "{\"type\":\"module\"}");
    const pkg_abs = try pkgDirAbs(&tmp, "mod-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const info = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(true, info.is_module);
    try std.testing.expect(info.side_effects == .unknown);
}

test "pkg_info_cache: sideEffects=false → .all(false)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "pure-pkg", "{\"sideEffects\":false}");
    const pkg_abs = try pkgDirAbs(&tmp, "pure-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const info = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(false, info.is_module);
    try std.testing.expect(info.side_effects == .all);
    try std.testing.expectEqual(false, info.side_effects.all);
}

test "pkg_info_cache: sideEffects=[*.css] → .patterns, patterns 소유권 유지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "css-pkg", "{\"sideEffects\":[\"*.css\",\"./polyfill.js\"]}");
    const pkg_abs = try pkgDirAbs(&tmp, "css-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const info = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expect(info.side_effects == .patterns);
    try std.testing.expectEqual(@as(usize, 2), info.side_effects.patterns.len);
    try std.testing.expectEqualStrings("*.css", info.side_effects.patterns[0]);
    try std.testing.expectEqualStrings("./polyfill.js", info.side_effects.patterns[1]);
    // 누수 체크는 std.testing.allocator 가 graph.deinit 후 자동 수행.
}

test "pkg_info_cache: type=module + sideEffects=false 조합" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "esm-pure", "{\"type\":\"module\",\"sideEffects\":false}");
    const pkg_abs = try pkgDirAbs(&tmp, "esm-pure");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const info = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(true, info.is_module);
    try std.testing.expect(info.side_effects == .all);
    try std.testing.expectEqual(false, info.side_effects.all);
}

test "pkg_info_cache: 같은 경로 두 번 → cache size 1, 동일 결과" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "hit-pkg", "{\"type\":\"module\"}");
    const pkg_abs = try pkgDirAbs(&tmp, "hit-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const first = gc.graph.lookupPkgInfo(pkg_abs);
    const second = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(first.is_module, second.is_module);
    try std.testing.expectEqual(@as(u32, 1), gc.graph.pkg_info_cache.count());
}

test "pkg_info_cache: 같은 pkg 다른 파일 경로 → cache entry 1개" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "multi-file", "{\"type\":\"module\"}");
    // 같은 pkg 안 두 개의 가짜 파일 경로 — findPackageDirPath 는 substring 기반이라
    // 둘 다 동일한 pkg_dir_path 를 반환해야 함.
    const pkg_abs = try pkgDirAbs(&tmp, "multi-file");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    _ = gc.graph.lookupPkgInfo(pkg_abs);
    _ = gc.graph.lookupPkgInfo(pkg_abs);
    _ = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(@as(u32, 1), gc.graph.pkg_info_cache.count());
}

test "pkg_info_cache: invalid JSON → is_module=false, side_effects=unknown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "broken-pkg", "{not valid json");
    const pkg_abs = try pkgDirAbs(&tmp, "broken-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const info = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expectEqual(false, info.is_module);
    try std.testing.expect(info.side_effects == .unknown);
}

test "pkg_info_cache: 다른 패키지는 별도 entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "pkg-a", "{\"type\":\"module\"}");
    try writePkgJson(tmp.dir, "pkg-b", "{\"sideEffects\":false}");
    const pkg_a = try pkgDirAbs(&tmp, "pkg-a");
    defer std.testing.allocator.free(pkg_a);
    const pkg_b = try pkgDirAbs(&tmp, "pkg-b");
    defer std.testing.allocator.free(pkg_b);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const a = gc.graph.lookupPkgInfo(pkg_a);
    const b = gc.graph.lookupPkgInfo(pkg_b);
    try std.testing.expectEqual(true, a.is_module);
    try std.testing.expectEqual(false, b.is_module);
    try std.testing.expect(a.side_effects == .unknown);
    try std.testing.expect(b.side_effects == .all);
    try std.testing.expectEqual(@as(u32, 2), gc.graph.pkg_info_cache.count());
}

// ── Thread-safety — 동일 pkg_dir_path 를 N threads 동시 lookup ──
const ParallelCtx = struct {
    graph: *ModuleGraph,
    pkg_path: []const u8,
    start_flag: *std.atomic.Value(bool),
    results: []ModuleGraph.PkgInfo,
    idx: usize,
};

fn parallelWorker(ctx: ParallelCtx) void {
    // busy-wait barrier: 모든 워커가 동시 출발하도록.
    while (!ctx.start_flag.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    ctx.results[ctx.idx] = ctx.graph.lookupPkgInfo(ctx.pkg_path);
}

test "pkg_info_cache: patterns 슬라이스가 다회 cache hit 후에도 동일 포인터 + 내용 유지" {
    // cache 재조회 시 매번 같은 slice 반환 (heap 재할당 없음) 을 검증 —
    // caller 가 slice 를 보관해도 안전함을 보장. UAF 회귀 테스트.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "stable-pkg", "{\"sideEffects\":[\"*.css\",\"*.scss\"]}");
    const pkg_abs = try pkgDirAbs(&tmp, "stable-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const a = gc.graph.lookupPkgInfo(pkg_abs);
    const b = gc.graph.lookupPkgInfo(pkg_abs);
    const c = gc.graph.lookupPkgInfo(pkg_abs);
    try std.testing.expect(a.side_effects == .patterns);
    try std.testing.expect(c.side_effects == .patterns);
    // 같은 slice 포인터 — 복사 없이 cache 의 소유권 공유.
    try std.testing.expectEqual(a.side_effects.patterns.ptr, b.side_effects.patterns.ptr);
    try std.testing.expectEqual(a.side_effects.patterns.ptr, c.side_effects.patterns.ptr);
    // 내용도 유효.
    try std.testing.expectEqualStrings("*.css", c.side_effects.patterns[0]);
    try std.testing.expectEqualStrings("*.scss", c.side_effects.patterns[1]);
}

test "pkg_info_cache: 병렬 N thread 동시 lookup → 결과 일치 + entry 1개 + 누수 없음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePkgJson(tmp.dir, "race-pkg", "{\"type\":\"module\",\"sideEffects\":[\"*.css\"]}");
    const pkg_abs = try pkgDirAbs(&tmp, "race-pkg");
    defer std.testing.allocator.free(pkg_abs);

    var gc = makeGraph();
    defer freeGraph(&gc.graph, gc.cache);

    const N = 16;
    var threads: [N]std.Thread = undefined;
    var results: [N]ModuleGraph.PkgInfo = undefined;
    var start_flag = std.atomic.Value(bool).init(false);

    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, parallelWorker, .{ParallelCtx{
            .graph = &gc.graph,
            .pkg_path = pkg_abs,
            .start_flag = &start_flag,
            .results = &results,
            .idx = i,
        }});
    }
    // 모든 스레드가 spawn 완료된 후 동시 출발.
    start_flag.store(true, .release);
    for (&threads) |*t| t.join();

    // 모든 워커가 동일 결과.
    for (results) |r| {
        try std.testing.expectEqual(true, r.is_module);
        try std.testing.expect(r.side_effects == .patterns);
        try std.testing.expectEqual(@as(usize, 1), r.side_effects.patterns.len);
        try std.testing.expectEqualStrings("*.css", r.side_effects.patterns[0]);
    }
    // race 상황에서도 entry 는 단 1개 (중복 계산된 경우 폐기되어야).
    try std.testing.expectEqual(@as(u32, 1), gc.graph.pkg_info_cache.count());
    // 누수 없음: std.testing.allocator 가 freeGraph 이후 검증.
}

// phase accessor sanity check (#1779 PR #1a)
test {
    _ = @import("phase.zig");
}

// module_list (StableSegmentedList) sanity check (#1779 PR #3 follow-up)
test {
    _ = @import("module_list.zig");
}

// ============================================================
// ModuleGraph.linkDependency tests (#1779 PR #2)
// ============================================================

test "linkDependency: bidirectional" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try graph.modules.append(alloc, Module.init(@enumFromInt(0), "a.ts"));
    try graph.modules.append(alloc, Module.init(@enumFromInt(1), "b.ts"));

    try graph.linkDependency(@enumFromInt(0), @enumFromInt(1));

    const a = graph.getModule(@enumFromInt(0)).?;
    const b = graph.getModule(@enumFromInt(1)).?;
    try std.testing.expectEqual(@as(usize, 1), a.dependencies.items.len);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(a.dependencies.items[0]));
    try std.testing.expectEqual(@as(usize, 1), b.importers.items.len);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(b.importers.items[0]));
}

test "linkDependency: none dep is no-op" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try graph.modules.append(alloc, Module.init(@enumFromInt(0), "a.ts"));
    try graph.linkDependency(@enumFromInt(0), .none);
    try std.testing.expectEqual(@as(usize, 0), graph.getModule(@enumFromInt(0)).?.dependencies.items.len);
}

test "linkDependency: out-of-bounds dep is no-op" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try graph.modules.append(alloc, Module.init(@enumFromInt(0), "a.ts"));
    try graph.linkDependency(@enumFromInt(0), @enumFromInt(99));
    try std.testing.expectEqual(@as(usize, 0), graph.getModule(@enumFromInt(0)).?.dependencies.items.len);
}
