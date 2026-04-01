const std = @import("std");
const graph_mod = @import("graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const determineExportsKind = graph_mod.determineExportsKind;
const Module = @import("module.zig").Module;
const types = @import("types.zig");
const import_scanner = @import("import_scanner.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
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

    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);
    try std.testing.expectEqual(@as(u32, 0), graph.modules.items[0].exec_index);
    try std.testing.expectEqual(Module.State.ready, graph.modules.items[0].state);
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

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);

    // DFS 후위: B가 먼저 (exec_index=0), A가 나중 (exec_index=1)
    const a_mod = graph.modules.items[0]; // a.ts가 먼저 addModule됨
    const b_mod = graph.modules.items[1];
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

    try std.testing.expectEqual(@as(usize, 3), graph.modules.items.len);

    // C=0, B=1, A=2 (후위 순서)
    const a = graph.modules.items[0];
    const b = graph.modules.items[1];
    const c = graph.modules.items[2];
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
    try std.testing.expectEqual(@as(usize, 4), graph.modules.items.len);

    // D가 가장 먼저 실행 (exec_index 최소)
    var min_exec: u32 = std.math.maxInt(u32);
    var min_path: []const u8 = "";
    for (graph.modules.items) |m| {
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
    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);

    var has_circular_warning = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .circular_dependency) has_circular_warning = true;
    }
    try std.testing.expect(has_circular_warning);
}

test "graph: external module — not in graph" {
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

    // react는 external이므로 그래프에 안 들어감
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);
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
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[0].dependencies.items.len);
    // B.importers에 A
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[1].importers.items.len);
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

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[0].dependencies.items.len);
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

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    // 둘 다 exec_index가 할당됨 (maxInt 아님)
    try std.testing.expect(graph.modules.items[0].exec_index != std.math.maxInt(u32));
    try std.testing.expect(graph.modules.items[1].exec_index != std.math.maxInt(u32));
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

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    // 동적 import는 dynamic_imports에, dependencies에는 없음
    try std.testing.expectEqual(@as(usize, 0), graph.modules.items[0].dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[0].dynamic_imports.items.len);
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

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    // JSON 모듈은 ESM AST로 변환됨 (export default <json>)
    const json_mod = graph.modules.items[1];
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

    const m = graph.modules.items[0];
    // semantic 데이터가 보존되어야 함
    try std.testing.expect(m.semantic != null);
    const sem = m.semantic.?;
    // exported_names에 x와 greet이 있어야 함
    try std.testing.expect(sem.exported_names.get("x") != null);
    try std.testing.expect(sem.exported_names.get("greet") != null);
    // symbols 배열이 비어있지 않아야 함
    try std.testing.expect(sem.symbols.len > 0);
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
    try std.testing.expect(graph.modules.items[0].semantic != null);
    // data.json도 ESM AST로 변환되므로 semantic 있음
    try std.testing.expect(graph.modules.items[1].semantic != null);
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

    const sem = graph.modules.items[0].semantic.?;
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
    const a = graph.modules.items[0];
    try std.testing.expect(a.import_bindings.len > 0);
    try std.testing.expectEqualStrings("x", a.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("x", a.import_bindings[0].imported_name);

    // a.ts: export_bindings에 y가 있어야 함
    try std.testing.expect(a.export_bindings.len > 0);
    try std.testing.expectEqualStrings("y", a.export_bindings[0].exported_name);

    // b.ts: export_bindings에 x가 있어야 함
    const b = graph.modules.items[1];
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
