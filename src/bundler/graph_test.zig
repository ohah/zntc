const std = @import("std");
const graph_mod = @import("graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const determineExportsKind = graph_mod.determineExportsKind;
const Module = @import("module.zig").Module;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const graph_parse_module = @import("graph/parse_module.zig");
const renumber_mod = @import("graph/renumber.zig");
const import_scanner = @import("import_scanner.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const module_store_mod = @import("module_store.zig");
const plugin_mod = @import("plugin.zig");
const Plugin = plugin_mod.Plugin;
const pkg_json = @import("package_json.zig");
const writeFile = @import("test_helpers.zig").writeFile;

fn createFile(dir: std.Io.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.createDirPath(std.testing.io, parent) catch {};
    }
    const file = try dir.createFile(std.testing.io, path, .{});
    file.close(std.testing.io);
}

fn dirPath(tmp: *std.testing.TmpDir) ![:0]u8 {
    return try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

    // a.ts + phantom react = 2 modules. react phantom 의 is_external = true.
    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());
    const react_idx = graph.path_to_module.get("react") orelse return error.TestUnexpectedResult;
    const react_mod = graph.getModule(react_idx) orelse return error.TestUnexpectedResult;
    try std.testing.expect(react_mod.is_external);
    // record 의 is_external 도 그대로 set (emit/linker 호환)
    const a_mod = graph.getModule(@fromBackingInt(@intCast(0))) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_mod.import_records[0].is_external);

    // 양방향 link 도 등록되어야 — a 의 dependencies 에 react, react 의 importers 에 a
    try std.testing.expect(a_mod.dependencies.items.len == 1);
    try std.testing.expect(a_mod.dependencies.items[0] == react_idx);
    try std.testing.expect(react_mod.importers.items.len == 1);
    try std.testing.expect(@backingInt(react_mod.importers.items[0]) == 0);
}

test "graph: 같은 external 을 여러 모듈이 import → phantom 1개 공유" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import 'shared-ext';");
    try writeFile(tmp.dir, "b.ts", "import 'shared-ext';");
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\import './b';
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"shared-ext"} });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    // entry + a + b + 1 phantom shared-ext = 4
    try std.testing.expectEqual(@as(usize, 4), graph.moduleCount());
    const ext_idx = graph.path_to_module.get("shared-ext") orelse return error.TestUnexpectedResult;
    const ext_mod = graph.getModule(ext_idx) orelse return error.TestUnexpectedResult;
    // a, b 둘 다 importer 로 등록
    try std.testing.expectEqual(@as(usize, 2), ext_mod.importers.items.len);
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

    try graph.build(std.testing.io, &.{entry});

    // 에러 diagnostic 있어야 함
    var has_unresolved = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .unresolved_import) has_unresolved = true;
    }
    try std.testing.expect(has_unresolved);
}

test "graph: unresolved import — 진단 1회만 (중복 방지 회귀)" {
    // #3966 후속: hard-error 로 실패한 record 는 resolve_failed 로 마킹되어
    // applyScanResult 의 직접 호출 + 후속 resolveModuleImports 양쪽에서 재처리되지
    // 않는다. value usage 가 있어 hard-error 경로(soft-fail 아님)를 타게 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import x from './nonexistent';\nconsole.log(x);");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    // 같은 unresolved import 에 대한 error 진단은 정확히 1개여야 한다 (중복 출력 버그 가드).
    var unresolved_errors: usize = 0;
    for (graph.diagnostics.items) |d| {
        if (d.code == .unresolved_import and d.severity == .@"error") unresolved_errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unresolved_errors);
}

test "graph: non-literal dynamic import — string-literal reason warning 1회 (#3984)" {
    // 비-literal `import(name)` 은 generic "Cannot resolve module" 가 아니라
    // dynamic_invalid_reason("...string literal specifier...") warning 을 정확히
    // 1회 emit 해야 한다. (#3973 의 resolve_failed 마킹이 worker-scan 경로에서
    // 올바른 메시지를 죽이던 회귀 가드.)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const name = './mod';\nexport const p = import(name);\nconsole.log('entry');");
    try writeFile(tmp.dir, "mod.ts", "export default 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    var reason_warnings: usize = 0;
    var generic_cannot_resolve: usize = 0;
    for (graph.diagnostics.items) |d| {
        if (d.code != .unresolved_import) continue;
        if (std.mem.indexOf(u8, d.message, "string literal") != null) reason_warnings += 1;
        if (std.mem.eql(u8, d.message, "Cannot resolve module")) generic_cannot_resolve += 1;
    }
    // 정확히 1회의 reason warning, generic 메시지는 0회.
    try std.testing.expectEqual(@as(usize, 1), reason_warnings);
    try std.testing.expectEqual(@as(usize, 0), generic_cannot_resolve);
}

test "graph: unresolved type-only import — soft fail with warning (#2466)" {
    // react-native-screens/types 패턴: subpath 가 .d.ts 만 export 하므로 resolve 실패하지만
    // X 가 type position 에서만 쓰이면 babel typescript preset 처럼 statement 통째 elide
    // 되어야 함. ZNTC 는 hard fail 대신 warning + disabled stub.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { X } from './nonexistent';
        \\const fn = (x: X) => x;
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    // error 가 아니라 warning 이어야 함.
    var error_count: usize = 0;
    var warning_count: usize = 0;
    for (graph.diagnostics.items) |d| {
        if (d.code != .unresolved_import) continue;
        switch (d.severity) {
            .@"error" => error_count += 1,
            .warning => warning_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), error_count);
    try std.testing.expect(warning_count >= 1);
}

test "graph: unresolved import with value usage — hard error (regression guard)" {
    // 한 binding 이라도 value 로 쓰이면 hard error. type-only soft fail 의 회귀 가드.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { X } from './nonexistent';
        \\console.log(X);
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    var has_error = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .unresolved_import and d.severity == .@"error") has_error = true;
    }
    try std.testing.expect(has_error);
}

test "graph: unresolved type-only import — many bindings (no hard cap)" {
    // 큰 type-only import (40 binding) 도 soft-fail 처리. esbuild/swc 처럼 한계 없음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import {
        \\  T01, T02, T03, T04, T05, T06, T07, T08, T09, T10,
        \\  T11, T12, T13, T14, T15, T16, T17, T18, T19, T20,
        \\  T21, T22, T23, T24, T25, T26, T27, T28, T29, T30,
        \\  T31, T32, T33, T34, T35, T36, T37, T38, T39, T40,
        \\} from './nonexistent';
        \\type Use = T01 | T02 | T20 | T40;
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    var error_count: usize = 0;
    for (graph.diagnostics.items) |d| {
        if (d.code != .unresolved_import) continue;
        if (d.severity == .@"error") error_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), error_count);
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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{ e1, e2 });

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

    try graph.build(std.testing.io, &.{entry});

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

test "graph: RN keeps abort-controller style Object.defineProperty exports as CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\import AbortController from "abort-controller";
        \\console.log(ac.AbortController);
    );
    try writeFile(tmp.dir, "node_modules/abort-controller/package.json",
        \\{"main":"dist/abort-controller.js"}
    );
    try writeFile(tmp.dir, "node_modules/abort-controller/dist/abort-controller.js",
        \\"use strict";
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\var eventTargetShim = require("event-target-shim");
        \\function AbortController() {}
        \\exports.AbortController = AbortController;
        \\exports.default = AbortController;
        \\module.exports = AbortController;
        \\module.exports.AbortController = module.exports["default"] = AbortController;
        \\module.exports.AbortSignal = eventTargetShim.EventTarget;
    );
    try writeFile(tmp.dir, "node_modules/event-target-shim/package.json",
        \\{"main":"index.js"}
    );
    try writeFile(tmp.dir, "node_modules/event-target-shim/index.js",
        \\exports.EventTarget = function EventTarget() {};
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.js" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{ .platform = .react_native });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(std.testing.io, &.{entry});

    var found = false;
    for (0..graph.moduleCount()) |i| {
        const m = graph.getModule(ModuleIndex.fromUsize(i)).?;
        if (std.mem.indexOf(u8, m.path, "abort-controller/dist/abort-controller.js") == null) continue;
        found = true;
        try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
        try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
    }
    try std.testing.expect(found);
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

test "matchSideEffectsPatterns: react-native-worklets style brace pattern" {
    const patterns = &[_][]const u8{"./**/runtimeKind.{js,ts}"};
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/react-native-worklets/src/runtimeKind.ts",
        "/app/node_modules/react-native-worklets",
        patterns,
    ));
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/react-native-worklets/lib/module/runtimeKind.js",
        "/app/node_modules/react-native-worklets",
        patterns,
    ));
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/react-native-worklets/src/runtimeKind.jsx",
        "/app/node_modules/react-native-worklets",
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
    try graph.build(std.testing.io, &.{entry});
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
    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try writeFile(tmp.dir, "entry.ts", "export const V = 2;");

    var empty: std.StringHashMapUnmanaged(void) = .empty;
    defer empty.deinit(std.testing.allocator);

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph2.deinit();
    const r = try graph2.buildIncremental(std.testing.io, &.{entry}, &store, &empty);
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

    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try writeFile(tmp.dir, "entry.ts", "export const V = 2;");

    var changed: std.StringHashMapUnmanaged(void) = .empty;
    defer changed.deinit(std.testing.allocator);
    try changed.put(std.testing.allocator, entry, {});

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph2.deinit();
    const r = try graph2.buildIncremental(std.testing.io, &.{entry}, &store, &changed);
    defer std.testing.allocator.free(r.reparsed_indices);

    // entry 가 changed set 에 있으므로 stat 정상 수행 → 새 mtime 으로 cache miss → reparse 1건.
    try std.testing.expectEqual(@as(usize, 1), r.reparsed_indices.len);
}

const ResolveCounter = struct {
    count: usize = 0,
    target: []const u8,
};

fn countedResolveHook(
    ctx: ?*anyopaque,
    specifier: []const u8,
    _: ?[]const u8,
    allocator: std.mem.Allocator,
    _: *plugin_mod.HookContext,
) plugin_mod.PluginError!?plugin_mod.ResolvedModule {
    const counter: *ResolveCounter = @ptrCast(@alignCast(ctx.?));
    counter.count += 1;
    if (std.mem.eql(u8, specifier, "alias:dep")) {
        return .{ .file = .{ .path = try allocator.dupe(u8, counter.target), .owner = .owned } };
    }
    return null;
}

test "buildIncremental: cache-hit modules replay resolved deps without resolver" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from 'alias:dep'; export const result = value;");
    try writeFile(tmp.dir, "dep.ts", "export const value = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);
    const dep = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "dep.ts" });
    defer std.testing.allocator.free(dep);

    var counter = ResolveCounter{ .target = dep };
    const plugins = [_]Plugin{.{
        .name = "counted-resolve",
        .context = &counter,
        .resolveId = countedResolveHook,
    }};

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();

    {
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        graph.plugins = &plugins;
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry});
        try std.testing.expect(counter.count > 0);

        for (0..graph.moduleCount()) |i| {
            const m = graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
            if (m.parse_arena == null) continue;
            store.putModule(m.path, m, m.mtime);
        }
    }

    counter.count = 0;
    var empty: std.StringHashMapUnmanaged(void) = .empty;
    defer empty.deinit(std.testing.allocator);

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    graph2.plugins = &plugins;
    defer graph2.deinit();
    const r = try graph2.buildIncremental(std.testing.io, &.{entry}, &store, &empty);
    defer std.testing.allocator.free(r.reparsed_indices);

    try std.testing.expectEqual(@as(usize, 0), r.reparsed_indices.len);
    try std.testing.expectEqual(@as(usize, 0), counter.count);
    try std.testing.expectEqual(@as(usize, 2), graph2.moduleCount());

    const entry_idx = graph2.path_to_module.get(entry) orelse return error.MissingEntry;
    const entry_mod = graph2.getModule(entry_idx) orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(usize, 1), entry_mod.dependencies.items.len);
    const dep_mod = graph2.getModule(entry_mod.dependencies.items[0]) orelse return error.MissingDep;
    try std.testing.expectEqualStrings(dep, dep_mod.path);
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

    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    try writeFile(tmp.dir, "entry.ts", "export const V = 2;");

    var graph2 = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph2.deinit();
    const r = try graph2.buildIncremental(std.testing.io, &.{entry}, &store, null);
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

    var empty: std.StringHashMapUnmanaged(void) = .empty;
    defer empty.deinit(std.testing.allocator);

    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    const r = try graph.buildIncremental(std.testing.io, &.{entry}, &store, &empty);
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
fn writePkgJson(tmp_dir: std.Io.Dir, pkg_name: []const u8, contents: []const u8) !void {
    var buf: [256]u8 = undefined;
    const rel = try std.fmt.bufPrint(&buf, "node_modules/{s}/package.json", .{pkg_name});
    try writeFile(tmp_dir, rel, contents);
}

/// 패키지 디렉토리 절대 경로 = tmp_root/node_modules/<pkg>. findPackageDirPath 검증용.
fn pkgDirAbs(tmp: *std.testing.TmpDir, pkg_name: []const u8) ![]u8 {
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
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

    const info = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const info = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const info = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const info = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const info = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const first = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
    const second = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    _ = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
    _ = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
    _ = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const info = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    const a = gc.graph.lookupPkgInfo(std.testing.io, pkg_a);
    const b = gc.graph.lookupPkgInfo(std.testing.io, pkg_b);
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
    ctx.results[ctx.idx] = ctx.graph.lookupPkgInfo(std.testing.io, ctx.pkg_path);
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

    const a = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
    const b = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
    const c = gc.graph.lookupPkgInfo(std.testing.io, pkg_abs);
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

    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(0)), "a.ts"));
    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(1)), "b.ts"));

    try graph.linkDependency(@fromBackingInt(@intCast(0)), @fromBackingInt(@intCast(1)));

    const a = graph.getModule(@fromBackingInt(@intCast(0))).?;
    const b = graph.getModule(@fromBackingInt(@intCast(1))).?;
    try std.testing.expectEqual(@as(usize, 1), a.dependencies.items.len);
    try std.testing.expectEqual(@as(u32, 1), @backingInt(a.dependencies.items[0]));
    try std.testing.expectEqual(@as(usize, 1), b.importers.items.len);
    try std.testing.expectEqual(@as(u32, 0), @backingInt(b.importers.items[0]));
}

test "linkDependency: none dep is no-op" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(0)), "a.ts"));
    try graph.linkDependency(@fromBackingInt(@intCast(0)), .none);
    try std.testing.expectEqual(@as(usize, 0), graph.getModule(@fromBackingInt(@intCast(0))).?.dependencies.items.len);
}

test "linkDependency: out-of-bounds dep is no-op" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(0)), "a.ts"));
    try graph.linkDependency(@fromBackingInt(@intCast(0)), @fromBackingInt(@intCast(99)));
    try std.testing.expectEqual(@as(usize, 0), graph.getModule(@fromBackingInt(@intCast(0))).?.dependencies.items.len);
}

test "renumber: empty graph is no-op" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try renumber_mod.renumberModulesDeterministically(&graph, &.{});
    try std.testing.expectEqual(@as(usize, 0), graph.modules.count());
}

test "renumber: orphan modules sorted by path regardless of add order" {
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    // 의도적 역순 add: c.ts → idx 0, b.ts → 1, a.ts → 2
    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(0)), "c.ts"));
    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(1)), "b.ts"));
    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(2)), "a.ts"));
    // PR-Z4: path_to_module key 는 path_arena 가 owned (graph deinit 시 일괄 해제).
    const arena_alloc = graph.path_arena.allocator();
    try graph.path_to_module.put(alloc, try arena_alloc.dupe(u8, "c.ts"), @fromBackingInt(@intCast(0)));
    try graph.path_to_module.put(alloc, try arena_alloc.dupe(u8, "b.ts"), @fromBackingInt(@intCast(1)));
    try graph.path_to_module.put(alloc, try arena_alloc.dupe(u8, "a.ts"), @fromBackingInt(@intCast(2)));

    try renumber_mod.renumberModulesDeterministically(&graph, &.{});

    // orphan path-sort 후: a.ts → 0, b.ts → 1, c.ts → 2
    try std.testing.expectEqualStrings("a.ts", graph.modules.at(0).path);
    try std.testing.expectEqualStrings("b.ts", graph.modules.at(1).path);
    try std.testing.expectEqualStrings("c.ts", graph.modules.at(2).path);
    try std.testing.expectEqual(@as(u32, 0), graph.path_to_module.get("a.ts").?.toU32());
    try std.testing.expectEqual(@as(u32, 1), graph.path_to_module.get("b.ts").?.toU32());
    try std.testing.expectEqual(@as(u32, 2), graph.path_to_module.get("c.ts").?.toU32());
    // Module.index 도 remap
    try std.testing.expectEqual(@as(u32, 0), graph.modules.at(0).index.toU32());
    try std.testing.expectEqual(@as(u32, 2), graph.modules.at(2).index.toU32());
}

test "renumber identity: 위상 불변이면 재renumber 가 멱등 (orphan path-sort)" {
    // 보존 경로 finalize/renumber skip 의 안전 근거: 같은 모듈 집합/순서를 다시 renumber 해도
    // old_to_new[i]==i (배치 불변). 위상이 안 바뀌면 renumber 가 출력에 영향 없음을 보장.
    const alloc = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(alloc, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(alloc, &cache);
    defer graph.deinit();

    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(0)), "c.ts"));
    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(1)), "b.ts"));
    try graph.modules.append(alloc, Module.init(@fromBackingInt(@intCast(2)), "a.ts"));
    const arena_alloc = graph.path_arena.allocator();
    try graph.path_to_module.put(alloc, try arena_alloc.dupe(u8, "c.ts"), @fromBackingInt(@intCast(0)));
    try graph.path_to_module.put(alloc, try arena_alloc.dupe(u8, "b.ts"), @fromBackingInt(@intCast(1)));
    try graph.path_to_module.put(alloc, try arena_alloc.dupe(u8, "a.ts"), @fromBackingInt(@intCast(2)));

    // 1회: a/b/c = 0/1/2 (path 정렬). 2·3회: 이미 정렬 → 멱등(불변).
    try renumber_mod.renumberModulesDeterministically(&graph, &.{});
    try renumber_mod.renumberModulesDeterministically(&graph, &.{});
    try renumber_mod.renumberModulesDeterministically(&graph, &.{});

    try std.testing.expectEqualStrings("a.ts", graph.modules.at(0).path);
    try std.testing.expectEqualStrings("b.ts", graph.modules.at(1).path);
    try std.testing.expectEqualStrings("c.ts", graph.modules.at(2).path);
    try std.testing.expectEqual(@as(u32, 0), graph.path_to_module.get("a.ts").?.toU32());
    try std.testing.expectEqual(@as(u32, 1), graph.path_to_module.get("b.ts").?.toU32());
    try std.testing.expectEqual(@as(u32, 2), graph.path_to_module.get("c.ts").?.toU32());
    for (0..3) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), graph.modules.at(i).index.toU32());
}

// F4 (Issue #65, PR #3704) 회귀 가드 — `buildIncremental` 가 stale entry_dir 를
// 강제 재계산해야 watch 모드에서 entry 추가/삭제 후 [dir] 토큰이 정확.
// 옛 코드는 `entry_dir.len == 0` 가드로 첫 build 후 영구 보존 → stale.
test "F4 (#65): buildIncremental 가 stale entry_dir 를 강제 재계산" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/a/index.ts", "export const X = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "src/a/index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();
    try populateStoreForChangedFilesTest(&cache, &store, entry);

    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    // stale entry_dir 시뮬레이션 — 무관한 dir 로 set. 옛 코드는 보존 (bug),
    // 새 코드는 entry_points 로부터 강제 재계산.
    // 0.16: entry_dir 는 graph-owned(buildIncremental 가 free 후 재dupe) 이므로
    // 리터럴이 아닌 allocator dupe 로 set 해야 free 가 안전.
    graph.entry_dir = try std.testing.allocator.dupe(u8, "/some/stale/parent/dir");

    var empty: std.StringHashMapUnmanaged(void) = .empty;
    defer empty.deinit(std.testing.allocator);

    const r = try graph.buildIncremental(std.testing.io, &.{entry}, &store, &empty);
    defer std.testing.allocator.free(r.reparsed_indices);

    // entry_dir 가 entry path 의 dirname 으로 갱신됐어야.
    const expected = std.fs.path.dirname(entry) orelse "";
    try std.testing.expectEqualStrings(expected, graph.entry_dir);
}

// F4 follow-up (post-review F1) — user-set project_root 보존:
// buildIncremental 가 entry_dir 갱신 시 project_root 를 함부로 invalidate
// 하면 RN/Metro 의 `projectRoot` 명시 설정이 watch session 중 자동 추론값
// 으로 silently 덮어쓰여진다. 자동 추론은 *최초* 빈 값일 때만.
test "F4 follow-up: buildIncremental 는 user-set project_root 를 보존" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/index.ts", "export const X = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "src/index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var store = module_store_mod.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();
    try populateStoreForChangedFilesTest(&cache, &store, entry);

    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    // RN/Metro 시뮬레이션 — user 가 monorepo root 명시.
    const user_project_root = "/repo/monorepo-root";
    graph.project_root = user_project_root;

    var empty: std.StringHashMapUnmanaged(void) = .empty;
    defer empty.deinit(std.testing.allocator);

    const r = try graph.buildIncremental(std.testing.io, &.{entry}, &store, &empty);
    defer std.testing.allocator.free(r.reparsed_indices);

    // user-set project_root 보존 — buildIncremental 이 강제 invalidate 하면
    // RN/Metro asset httpServerLocation 어긋남.
    try std.testing.expectEqualStrings(user_project_root, graph.project_root);
}

// ============================================================
// Sub-PR-B.1: ModuleGraph.reset / invalidateModule API tests
// RFC_GRAPH_PERSISTENCE — 호출자 없음 (Sub-PR-B.3 에서 wire-up). 본 단위 테스트는
// API 의 부분 정확성만 — graph-global state clear + module-local state reset.
// ============================================================

test "graph.reset: modules + path_to_module 보존, diagnostics/worker_entries clear" {
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

    try graph.build(std.testing.io, &.{entry});

    const mod_count_before = graph.moduleCount();
    const path_count_before = graph.path_to_module.count();
    try std.testing.expect(mod_count_before >= 2);

    // 인위적으로 graph-global state 채우기 — diagnostics + worker_entries
    const Span = @import("../lexer/token.zig").Span;
    try graph.diagnostics.append(graph.allocator, .{
        .code = .parse_error,
        .severity = .warning,
        .message = "synthetic diag",
        .file_path = "synthetic.ts",
        .span = Span.EMPTY,
        .step = .parse,
    });
    const synthetic_path = try graph.allocator.dupe(u8, "/tmp/worker.ts");
    try graph.worker_entries.append(graph.allocator, .{
        .resolved_path = synthetic_path,
        .source_module = ModuleIndex.fromUsize(0),
        .record_index = 0,
    });
    graph.exec_counter = 42;
    graph.cycle_counter = 7;

    // reset 호출
    graph.reset();

    // modules 보존
    try std.testing.expectEqual(mod_count_before, graph.moduleCount());
    try std.testing.expectEqual(path_count_before, graph.path_to_module.count());
    // graph-global state cleared
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.worker_entries.items.len);
    try std.testing.expectEqual(@as(u32, 0), graph.exec_counter);
    try std.testing.expectEqual(@as(u32, 0), graph.cycle_counter);
}

test "graph.invalidateModule: path 보존, ast/semantic/resolved_deps clear" {
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

    try graph.build(std.testing.io, &.{entry});

    const target_idx = ModuleIndex.fromUsize(0);
    const path_before = graph.getModule(target_idx).?.path;
    const path_dupe = try std.testing.allocator.dupe(u8, path_before);
    defer std.testing.allocator.free(path_dupe);

    // build 후엔 ast / semantic 채워져 있음
    try std.testing.expect(graph.getModule(target_idx).?.state == .ready);

    graph.invalidateModule(target_idx);

    // path 보존 (path_arena 가 소유)
    try std.testing.expectEqualStrings(path_dupe, graph.getModule(target_idx).?.path);
    // module state 가 reserved (build 시작 상태) 로 reset
    try std.testing.expectEqual(Module.State.reserved, graph.getModule(target_idx).?.state);
    // ast / semantic null
    try std.testing.expect(graph.getModule(target_idx).?.ast == null);
    try std.testing.expect(graph.getModule(target_idx).?.semantic == null);
    // resolved_deps clear
    try std.testing.expectEqual(@as(usize, 0), graph.getModule(target_idx).?.resolved_deps.items.len);
}

test "graph: 디스크 캐시 키 캡처 — 활성 시 모듈별 키 (#4438)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import { a } from './a'; console.log(a);");
    try writeFile(tmp.dir, "a.ts", "export const a = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    var store = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer store.deinit();
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = &store;
    graph.disk_options_hash = 0x1234;
    graph.disk_compiler_build_id = 0xABCD;

    try graph.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());

    // 두 모듈 모두 키가 캡처(0 아님)되고, source 가 다르니 키도 다르다.
    const k0 = graph.getModule(ModuleIndex.fromUsize(0)).?.disk_cache_key;
    const k1 = graph.getModule(ModuleIndex.fromUsize(1)).?.disk_cache_key;
    try std.testing.expect(k0 != 0 and k1 != 0);
    try std.testing.expect(k0 != k1);
}

test "graph: 디스크 캐시 비활성 시 키 미설정 (#4438)" {
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
    // disk_cache = null (기본) → parseModule 이 키 계산을 skip.

    try graph.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(u64, 0), graph.getModule(ModuleIndex.fromUsize(0)).?.disk_cache_key);
}

test "graph: 디스크 캐시 store — build 시 모듈 영속화 + load round-trip (#4438)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import { a } from './a'; console.log(a);");
    try writeFile(tmp.dir, "a.ts", "export const a = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    var store = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer store.deinit();
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.disk_cache = &store;
    graph.disk_options_hash = 0x1234;
    graph.disk_compiler_build_id = 0xABCD;

    try graph.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 2), graph.moduleCount());

    // store 가 build 중 두 모듈을 디스크에 썼으면, 같은 키로 load 가 복원한다 — 실제 모듈
    // AST+semantic codec round-trip self-check (load 는 테스트 전용, 파이프라인 미연결).
    const k0 = graph.getModule(ModuleIndex.fromUsize(0)).?.disk_cache_key;
    const k1 = graph.getModule(ModuleIndex.fromUsize(1)).?.disk_cache_key;
    try std.testing.expect(k0 != 0 and k1 != 0);

    // 복원본(ast.source 포함)은 arena 소유 — arena.deinit 가 일괄 회수(개별 deinit 금지).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r0 = try store.load(std.testing.io, std.testing.allocator, arena.allocator(), k0);
    try std.testing.expect(r0 != null);
    const r1 = try store.load(std.testing.io, std.testing.allocator, arena.allocator(), k1);
    try std.testing.expect(r1 != null);

    // 미저장 키는 miss(null)로 degrade — fail-safe.
    const miss = try store.load(std.testing.io, std.testing.allocator, arena.allocator(), 0xDEADBEEF);
    try std.testing.expect(miss == null);
}

/// #4438 통합3 PR1: build 직후 module(=정상 materialize 결과, ground truth)을 캡처하고,
/// parser 없이 `materializeFromCachedAst`(헬퍼)로 같은 module.ast 를 재구성한 뒤 graph 레벨
/// 출력이 동등한지 검증한다. caller 는 pre-pass 미실행 fixture(.mjs/.cjs, minify off)를 써서
/// module.* 가 materialize 결과 그대로 남도록 한다(헬퍼=resync 기반과 진짜 비교).
fn expectCachedAstMaterializeEquivalent(graph: *ModuleGraph) !void {
    const m = graph.modules.at(0);
    const arena_alloc = m.parse_arena.?.allocator();
    const semantic = m.semantic orelse return error.TestExpectedSemantic;
    const original_ids = try std.testing.allocator.dupe(?u32, semantic.symbol_ids);
    defer std.testing.allocator.free(original_ids);
    const original_references = try std.testing.allocator.dupe(@import("../semantic/symbol.zig").Reference, semantic.references);
    defer std.testing.allocator.free(original_references);
    const original_scopes = try std.testing.allocator.dupe(@import("../semantic/scope.zig").Scope, semantic.scopes);
    defer std.testing.allocator.free(original_scopes);

    // ground truth (materialize 결과) 캡처.
    const gt_kind = m.exports_kind;
    const gt_wrap = m.wrap_kind;
    const gt_exported = m.exported_names.len;
    const gt_import_bindings = m.import_bindings;
    const gt_export_bindings = m.export_bindings;
    const gt_statements = m.prebuilt_stmt_info;
    const gt_self_tla = m.self_uses_top_level_await;
    const gt_specs = try std.testing.allocator.alloc([]const u8, m.import_records.len);
    defer {
        for (gt_specs) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(gt_specs);
    }
    for (m.import_records, 0..) |r, i| gt_specs[i] = try std.testing.allocator.dupe(u8, r.specifier);

    // 실제 load(fresh module)는 graph-level 필드가 비어있다 — import_records 를 비워
    // resync 의 mergeImportRecords(previous=empty)가 load 와 동일 경로를 타게 한다.
    m.import_records = &.{};
    m.import_bindings = &.{};
    m.export_bindings = &.{};
    m.exported_names = &.{};
    m.namespace_access_index = null;
    m.prebuilt_stmt_info = null;
    m.self_uses_top_level_await = !gt_self_tla;
    m.uses_top_level_await = !gt_self_tla;

    // parser 없이 module.ast 만으로 재구성.
    try graph.materializeFromCachedAst(m, arena_alloc);

    // The cache already restored the parse AST and its semantic graph. Metadata
    // reconstruction must not replace that graph with a second analysis.
    try std.testing.expectEqualSlices(?u32, original_ids, m.semantic.?.symbol_ids);
    try std.testing.expectEqualDeep(original_references, m.semantic.?.references);
    try std.testing.expectEqualDeep(original_scopes, m.semantic.?.scopes);

    // materialize 와 동등해야 한다.
    try std.testing.expectEqual(gt_kind, m.exports_kind);
    try std.testing.expectEqual(gt_wrap, m.wrap_kind);
    try std.testing.expectEqual(gt_exported, m.exported_names.len);
    try std.testing.expectEqual(gt_self_tla, m.self_uses_top_level_await);
    try std.testing.expectEqual(gt_self_tla, m.uses_top_level_await);
    try std.testing.expectEqual(gt_specs.len, m.import_records.len);
    for (gt_specs, m.import_records) |g, r| try std.testing.expectEqualStrings(g, r.specifier);
    try std.testing.expectEqual(gt_import_bindings.len, m.import_bindings.len);
    for (gt_import_bindings, m.import_bindings) |old, new| {
        try std.testing.expectEqual(old.kind, new.kind);
        try std.testing.expectEqualStrings(old.local_name, new.local_name);
        try std.testing.expectEqualStrings(old.imported_name, new.imported_name);
        try std.testing.expectEqual(old.local_symbol_node, new.local_symbol_node);
        if (old.local_symbol_node) |node| {
            try std.testing.expectEqual(semantic.symbol_ids[@backingInt(node)], new.local_symbol.semanticIndex());
            try std.testing.expectEqual(m.index, new.local_symbol.moduleIndex());
        }
    }
    try std.testing.expectEqual(gt_export_bindings.len, m.export_bindings.len);
    for (gt_export_bindings, m.export_bindings) |old, new| {
        try std.testing.expectEqual(old.kind, new.kind);
        try std.testing.expectEqualStrings(old.local_name, new.local_name);
        try std.testing.expectEqualStrings(old.exported_name, new.exported_name);
        try std.testing.expectEqual(old.local_symbol_node, new.local_symbol_node);
        if (old.local_symbol_node) |node| {
            const local_sid = semantic.symbol_ids[@backingInt(node)];
            try std.testing.expect(local_sid != null);
            if (old.kind == .local) {
                try std.testing.expectEqual(local_sid, new.symbol.semanticIndex());
                try std.testing.expectEqual(m.index, new.symbol.moduleIndex());
            } else {
                // A local-syntax barrel retains its local reference anchor,
                // while the export symbol still owns the separate alias role.
                try std.testing.expectEqual(old.symbol.semanticIndex(), new.symbol.semanticIndex());
                var found_local = false;
                for (m.import_bindings) |binding| {
                    if (binding.import_record_index != new.import_record_index) continue;
                    if (binding.local_symbol.semanticIndex() == local_sid) found_local = true;
                }
                try std.testing.expect(found_local);
            }
        }
    }
    if (gt_statements) |old| {
        const new = m.prebuilt_stmt_info orelse return error.TestExpectedStatements;
        try std.testing.expectEqual(old.stmts.len, new.stmts.len);
        for (old.stmts, new.stmts) |a, b| {
            try std.testing.expectEqual(a.node_idx, b.node_idx);
            try std.testing.expectEqual(a.has_side_effects, b.has_side_effects);
            try std.testing.expectEqualSlices(u32, a.declared_symbols, b.declared_symbols);
            try std.testing.expectEqualSlices(u32, a.referenced_symbols, b.referenced_symbols);
        }
    }
    if (gt_import_bindings.len > 0) try std.testing.expect(m.namespace_access_index != null);
}

test "graph: materializeFromCachedAst — ESM 동등 재구성 (#4438 통합3 PR1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // .mjs: TS strip 없음 + ESM + minify off → transformer pre-pass 미실행 → module.* =
    // materialize 결과 그대로(ground truth). import + named export + re-export 커버.
    try writeFile(tmp.dir, "index.mjs", "import { a } from './a.mjs'; export const b = a + 1; export { a };");
    try writeFile(tmp.dir, "a.mjs", "export const a = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.mjs" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    try expectCachedAstMaterializeEquivalent(&graph);
}

test "graph: materializeFromCachedAst — CJS 동등 재구성 (#4438 통합3 PR1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // .cjs: require + module.exports → exports_kind=.commonjs / wrap_kind=.cjs 경로 커버.
    try writeFile(tmp.dir, "index.cjs", "const a = require('./a.cjs'); module.exports = a.x + 1;");
    try writeFile(tmp.dir, "a.cjs", "module.exports = { x: 1 };");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.cjs" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    try expectCachedAstMaterializeEquivalent(&graph);
}

test "graph: materializeFromCachedAst preserves non-parser-order cached SymbolIds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.mjs", "export const first = 1; export const second = first + 1;");
    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.mjs" });
    defer std.testing.allocator.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const m = graph.modules.at(0);
    const sem = &m.semantic.?;
    try std.testing.expectEqual(@as(usize, 2), sem.symbols.items.len);
    // Valid cached graphs need not enumerate symbols in parser declaration
    // order. Swap both symbols and every semantic edge so a fresh analyzer
    // cannot silently replace this snapshot with its own numbering.
    std.mem.swap(@import("../semantic/symbol.zig").Symbol, &sem.symbols.items[0], &sem.symbols.items[1]);
    for (@constCast(sem.symbol_ids)) |*id| {
        if (id.*) |value| id.* = 1 - value;
    }
    for (@constCast(sem.references)) |*reference| reference.symbol_id = @fromBackingInt(1 - @backingInt(reference.symbol_id));
    var bindings = sem.scope_maps[0].valueIterator();
    while (bindings.next()) |id| id.* = 1 - id.*;
    var remapped_numeric_texts: @TypeOf(sem.numeric_const_texts) = .empty;
    var numeric_texts = sem.numeric_const_texts.iterator();
    while (numeric_texts.next()) |item| try remapped_numeric_texts.put(m.parse_arena.?.allocator(), 1 - item.key_ptr.*, item.value_ptr.*);
    sem.numeric_const_texts = remapped_numeric_texts;
    const module_codec = @import("module_codec.zig");
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try module_codec.serialize(&m.ast.?, sem, &encoded, std.testing.allocator);
    const restored = try module_codec.deserialize(encoded.items, m.parse_arena.?.allocator());
    m.ast = restored.ast;
    m.semantic = restored.semantic;
    m.prebuilt_stmt_info = null;
    try expectCachedAstMaterializeEquivalent(&graph);
    try std.testing.expectEqual(@as(?usize, 1), m.semantic.?.scope_maps[0].get("first"));
    try std.testing.expectEqual(@as(?usize, 0), m.semantic.?.scope_maps[0].get("second"));
}

test "graph: materializeFromCachedAst preserves exact cached graph across module forms" {
    const cases = [_]struct { path: []const u8, source: []const u8, tla: bool = false }{
        .{ .path = "index.mjs", .source = "export const value = 1;" },
        .{ .path = "index.mjs", .source = "export default function value() { return 1; }" },
        .{ .path = "index.mjs", .source = "export default class Value { read() { return Value; } }" },
        .{ .path = "index.mjs", .source = "const value = 1; export function read(value) { return () => value; } console.log(value);" },
        .{ .path = "index.mjs", .source = "import * as ns from './a.mjs'; export const value = ns.a;" },
        .{ .path = "index.mjs", .source = "export { a as answer } from './a.mjs';" },
        .{ .path = "index.mjs", .source = "await Promise.resolve(1); export const value = 1;", .tla = true },
        .{ .path = "index.mjs", .source = "export async function read() { return await Promise.resolve(1); }" },
        .{ .path = "index.cjs", .source = "with ({ value: 1 }) { console.log(value); } module.exports = 1;" },
        .{ .path = "index.cjs", .source = "const value = require('./a.cjs'); exports.value = value.a;" },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, case.path, case.source);
        try writeFile(tmp.dir, "a.mjs", "export const a = 1;");
        try writeFile(tmp.dir, "a.cjs", "exports.a = 1;");
        const dp = try dirPath(&tmp);
        defer std.testing.allocator.free(dp);
        const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, case.path });
        defer std.testing.allocator.free(entry);
        var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry});
        try expectCachedAstMaterializeEquivalent(&graph);
        const m = graph.modules.at(0);
        try std.testing.expectEqual(case.tla, m.self_uses_top_level_await);
    }
}

test "graph: load hit — 복원 module 이 cold parse 와 동등 + parse 스킵 (#4438 통합3 PR2)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.mjs", "import { a } from './a.mjs'; export const b = a + 1; export { a };");
    try writeFile(tmp.dir, "a.mjs", "export const a = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.mjs" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    // ground truth — 1st build: 캐시 empty → miss → parse + store.
    var gt_specs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (gt_specs.items) |s| std.testing.allocator.free(s);
        gt_specs.deinit(std.testing.allocator);
    }
    var gt_kind: types.ExportsKind = undefined;
    var gt_exported: usize = 0;
    var gt_count: usize = 0;
    {
        var store1 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
        defer store1.deinit();
        var c1 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer c1.deinit();
        var g1 = ModuleGraph.init(std.testing.allocator, &c1);
        defer g1.deinit();
        g1.disk_cache = &store1;
        g1.disk_options_hash = 0x1234;
        g1.disk_compiler_build_id = 0xABCD;
        g1.disk_load_enabled = true;
        try g1.build(std.testing.io, &.{entry});
        try std.testing.expectEqual(@as(usize, 0), g1.disk_load_hits.load(.monotonic)); // empty → 전부 miss
        const m1 = g1.modules.at(0);
        gt_kind = m1.exports_kind;
        gt_exported = m1.exported_names.len;
        gt_count = g1.moduleCount();
        for (m1.import_records) |r| try gt_specs.append(std.testing.allocator, try std.testing.allocator.dupe(u8, r.specifier));
    }

    // 2nd build: 캐시 채워짐 → load hit (parse 스킵).
    var store2 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer store2.deinit();
    var c2 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer c2.deinit();
    var g2 = ModuleGraph.init(std.testing.allocator, &c2);
    defer g2.deinit();
    g2.disk_cache = &store2;
    g2.disk_options_hash = 0x1234; // 1st 와 같은 키 dimension → hit
    g2.disk_compiler_build_id = 0xABCD;
    g2.disk_load_enabled = true;
    try g2.build(std.testing.io, &.{entry});

    // parse 스킵 증거: load hit > 0.
    try std.testing.expect(g2.disk_load_hits.load(.monotonic) > 0);
    // cold parse 와 동등 (모듈 수 / exports_kind / exported_names / import_records specifier).
    try std.testing.expectEqual(gt_count, g2.moduleCount());
    const m2 = g2.modules.at(0);
    try std.testing.expectEqual(gt_kind, m2.exports_kind);
    try std.testing.expectEqual(gt_exported, m2.exported_names.len);
    try std.testing.expectEqual(gt_specs.items.len, m2.import_records.len);
    for (gt_specs.items, m2.import_records) |g, r| try std.testing.expectEqualStrings(g, r.specifier);
}

/// (#5571/#5581/#5583) TypeScript type-only facts judged on the parse AST.
const TsTypeFacts = struct { record_elided: bool, binding_type_only: ?bool, type_names: usize };

fn buildTsTypeFacts(entry: []const u8, cache_root: []const u8, expect_hit: bool) !TsTypeFacts {
    var store = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer store.deinit();
    var c = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer c.deinit();
    var g = ModuleGraph.init(std.testing.allocator, &c);
    defer g.deinit();
    g.disk_cache = &store;
    g.disk_compiler_build_id = 0xABCD;
    g.disk_load_enabled = true;
    try g.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(expect_hit, g.disk_load_hits.load(.monotonic) > 0);
    var facts: TsTypeFacts = .{ .record_elided = false, .binding_type_only = null, .type_names = 0 };
    for (0..g.moduleCount()) |i| {
        const m = g.modules.at(i);
        if (std.mem.endsWith(u8, m.path, "entry.ts")) {
            facts.record_elided = m.import_records[0].ts_elided;
            facts.binding_type_only = m.import_bindings[0].source_type_only;
        } else if (std.mem.endsWith(u8, m.path, "types.ts")) {
            facts.type_names = m.ts_type_export_names.count();
        }
    }
    return facts;
}

test "graph: load hit — TS 타입 전용 판정이 cold parse 와 같다 (#5583)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "types.ts", "export interface T { n: number }\nexport declare const g: number;\nexport type U = string;\nexport const v = 1;\n");
    try writeFile(tmp.dir, "entry.ts", "import { T } from './types';\nexport { U, v } from './types';\nlet t: T | null = null;\nconsole.log(t);\n");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    const cold = try buildTsTypeFacts(entry, cache_root, false);
    try std.testing.expect(cold.record_elided);
    try std.testing.expectEqual(@as(?bool, true), cold.binding_type_only);
    try std.testing.expectEqual(@as(usize, 3), cold.type_names); // T, g, U
    const loaded = try buildTsTypeFacts(entry, cache_root, true);
    try std.testing.expectEqual(cold, loaded);
}

test "graph: TS import type-use classification keeps exact binding across hostile inputs" {
    const cases = [_]struct { local_name: []const u8, source: []const u8, expect_type_only: bool }{
        .{ .local_name = "Named0", .source = "import { T as Named0 } from './types';\ntype Use = Named0;\n", .expect_type_only = true },
        .{ .local_name = "Named1", .source = "import { T as Named1 } from './types';\ninterface Use extends Named1 {}\n", .expect_type_only = true },
        .{ .local_name = "Named2", .source = "import { U as Named2 } from './types';\ntype Use<T extends Named2> = T;\n", .expect_type_only = true },
        .{ .local_name = "Named3", .source = "import { T as Named3 } from './types';\nfunction use(value: Named3): void {}\n", .expect_type_only = true },
        .{ .local_name = "Named4", .source = "import { T as Named4 } from './types';\nclass Use implements Named4 { n = 1; }\n", .expect_type_only = true },
        .{ .local_name = "Named5", .source = "import { T as Named5 } from './types';\nclass Use { value!: Named5; }\n", .expect_type_only = true },
        .{ .local_name = "Defaulted", .source = "import Defaulted from './types';\ntype Use = typeof Defaulted;\n", .expect_type_only = true },
        .{ .local_name = "NS", .source = "import * as NS from './types';\ntype Use = NS.T;\n", .expect_type_only = true },
        .{ .local_name = "NS2", .source = "import * as NS2 from './types';\ntype Use = keyof typeof NS2;\n", .expect_type_only = true },
        .{ .local_name = "Named9", .source = "import { T as Named9 } from './types';\ntype Use<T> = T extends Named9 ? Named9 : never;\n", .expect_type_only = true },
        .{ .local_name = "NamedValue", .source = "import { T as NamedValue } from './types';\n", .expect_type_only = false },
    };

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(
            tmp.dir,
            "types.ts",
            "export interface T { n: number }\nexport interface U { n: string }\nexport default class Defaulted { n = 1; }\n",
        );
        const entry_source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}\nconst decoy = {{}};\nconsole.log({s});\n",
            .{ case.source, if (case.expect_type_only) "decoy" else "NamedValue" },
        );
        defer std.testing.allocator.free(entry_source);
        try writeFile(tmp.dir, "entry.ts", entry_source);

        const dp = try dirPath(&tmp);
        defer std.testing.allocator.free(dp);
        const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
        defer std.testing.allocator.free(entry_path);

        var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer cache.deinit();
        var graph = ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{entry_path});

        const entry_index = blk: {
            for (0..graph.moduleCount()) |index| {
                const candidate = graph.moduleAtMut(ModuleIndex.fromUsize(index)) orelse continue;
                if (std.mem.eql(u8, candidate.path, entry_path)) break :blk ModuleIndex.fromUsize(index);
            }
            return error.MissingEntryModule;
        };
        const entry = graph.moduleAtMut(entry_index) orelse return error.MissingEntryModule;
        if (entry.import_bindings.len != 1) return error.UnexpectedImportBindingCount;
        const semantic = if (entry.semantic) |*value| value else return error.MissingEntrySemantic;
        if (semantic.scope_maps.len == 0) return error.MissingEntryScopeMap;
        const scope = &semantic.scope_maps[0];
        const imported_symbol = scope.getPtr(case.local_name) orelse return error.MissingImportedSymbol;
        const decoy_symbol = scope.get("decoy") orelse return error.MissingDecoySymbol;
        const importer_ast = if (entry.ast) |*value| value else return error.MissingEntryAst;
        const arena_alloc = entry.parse_arena.?.allocator();
        const binding_node = entry.import_bindings[0].local_symbol_node orelse return error.MissingImportedBindingNode;
        const binding_node_index: usize = @intCast(@backingInt(binding_node));
        if (binding_node_index >= semantic.symbol_ids.len) return error.ImportedBindingNodeOutOfBounds;
        const binding_symbol_id = semantic.symbol_ids[binding_node_index] orelse return error.MissingImportedBindingSymbolId;
        const symbol_ids = @constCast(semantic.symbol_ids);
        try std.testing.expectEqual(imported_symbol.*, @as(usize, @intCast(binding_symbol_id)));
        const original_imported_symbol = imported_symbol.*;

        // Ten separate source shapes, each with a value-used decoy that
        // collides in the old spelling map but cannot change the exact SID.
        imported_symbol.* = decoy_symbol;
        entry.import_bindings[0].source_type_only = null;
        graph_parse_module.markSourceTypeOnlyImports(&graph, entry, importer_ast, arena_alloc);
        try std.testing.expectEqual(@as(?bool, case.expect_type_only), entry.import_bindings[0].source_type_only);
        try std.testing.expectEqual(case.expect_type_only, entry.import_records[0].ts_elided);

        // An in-range binding node without a SymbolId must fail closed rather
        // than classifying the hostile name-map decoy.
        symbol_ids[binding_node_index] = null;
        entry.import_bindings[0].source_type_only = null;
        graph_parse_module.markSourceTypeOnlyImports(&graph, entry, importer_ast, arena_alloc);
        try std.testing.expectEqual(@as(?bool, null), entry.import_bindings[0].source_type_only);
        try std.testing.expect(!entry.import_records[0].ts_elided);
        symbol_ids[binding_node_index] = binding_symbol_id;

        // An out-of-range SymbolId must also fail closed.
        symbol_ids[binding_node_index] = @intCast(semantic.symbols.items.len);
        entry.import_bindings[0].source_type_only = null;
        graph_parse_module.markSourceTypeOnlyImports(&graph, entry, importer_ast, arena_alloc);
        try std.testing.expectEqual(@as(?bool, null), entry.import_bindings[0].source_type_only);
        try std.testing.expect(!entry.import_records[0].ts_elided);
        symbol_ids[binding_node_index] = binding_symbol_id;

        // A valid ID of another binding kind is not an import identity.
        symbol_ids[binding_node_index] = @intCast(decoy_symbol);
        entry.import_bindings[0].source_type_only = null;
        graph_parse_module.markSourceTypeOnlyImports(&graph, entry, importer_ast, arena_alloc);
        try std.testing.expectEqual(@as(?bool, null), entry.import_bindings[0].source_type_only);
        try std.testing.expect(!entry.import_records[0].ts_elided);
        symbol_ids[binding_node_index] = binding_symbol_id;

        // Even a completely missing anchor must not classify a same-spelling
        // decoy. The value-used positive control would otherwise be elided.
        entry.import_bindings[0].local_symbol_node = null;
        entry.import_bindings[0].source_type_only = null;
        graph_parse_module.markSourceTypeOnlyImports(&graph, entry, importer_ast, arena_alloc);
        try std.testing.expectEqual(@as(?bool, null), entry.import_bindings[0].source_type_only);
        try std.testing.expect(!entry.import_records[0].ts_elided);

        // A present-but-invalid producer handle is different from a missing
        // handle and must not fall back to the name map either.
        entry.import_bindings[0].local_symbol_node = .none;
        entry.import_bindings[0].source_type_only = null;
        graph_parse_module.markSourceTypeOnlyImports(&graph, entry, importer_ast, arena_alloc);
        try std.testing.expectEqual(@as(?bool, null), entry.import_bindings[0].source_type_only);
        try std.testing.expect(!entry.import_records[0].ts_elided);

        entry.import_bindings[0].local_symbol_node = binding_node;
        imported_symbol.* = original_imported_symbol;
    }
}

test "graph: TS import record type-only classification is grouped by record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "types-a.ts", "export interface TypeA { a: string }\n");
    try writeFile(tmp.dir, "types-b.ts", "export interface TypeB { b: string }\n");
    try writeFile(tmp.dir, "value.ts", "export const value = 1;\n");
    try writeFile(tmp.dir, "entry.ts",
        \\import { TypeA } from './types-a';
        \\import { TypeB } from './types-b';
        \\import { value } from './value';
        \\export function f(a: TypeA, b: TypeB): number { return value; }
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    const module = graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expectEqual(@as(usize, 3), module.import_records.len);
    try std.testing.expect(module.import_records[0].ts_elided);
    try std.testing.expect(module.import_records[1].ts_elided);
    try std.testing.expect(!module.import_records[2].ts_elided);
    try std.testing.expectEqual(@as(?bool, true), module.import_records[0].ts_all_bindings_type_only);
    try std.testing.expectEqual(@as(?bool, true), module.import_records[1].ts_all_bindings_type_only);
    try std.testing.expectEqual(@as(?bool, false), module.import_records[2].ts_all_bindings_type_only);
}

test "graph: verbatim TS import keeps output but records type-only evaluation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "types.ts", "export interface TypeA { a: string }\n");
    try writeFile(tmp.dir, "entry.ts",
        \\import { TypeA } from './types';
        \\export function f(a: TypeA): string { return a.a; }
    );

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.transform_options_base.verbatim_module_syntax = true;
    try graph.build(std.testing.io, &.{entry});

    const module = graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expectEqual(@as(usize, 1), module.import_records.len);
    try std.testing.expect(!module.import_records[0].ts_elided);
    try std.testing.expectEqual(@as(?bool, true), module.import_records[0].ts_all_bindings_type_only);
}

test "graph: load hit 게이트 — legal comment 모듈은 load OFF (#4438 통합3 PR2)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // @license 마커 → loadUnsafeSource 게이트 → 캐시가 있어도 load OFF(cold parse) → hit 0.
    // (lazy-barrel elision 이 module.legal_comments 를 읽는데 load 는 빈 배열이라 banner 누락 방지.)
    try writeFile(tmp.dir, "index.mjs", "/*! @license MIT */\nexport const x = 1;\n");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.mjs" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    // 1st build: store 진행(게이트는 load 만 막음).
    {
        var s1 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
        defer s1.deinit();
        var c1 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer c1.deinit();
        var g1 = ModuleGraph.init(std.testing.allocator, &c1);
        defer g1.deinit();
        g1.disk_cache = &s1;
        g1.disk_compiler_build_id = 0xABCD;
        g1.disk_load_enabled = true;
        try g1.build(std.testing.io, &.{entry});
    }

    // 2nd build: 캐시 채워졌지만 legal comment 게이트로 load OFF → hit 0.
    var s2 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer s2.deinit();
    var c2 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer c2.deinit();
    var g2 = ModuleGraph.init(std.testing.allocator, &c2);
    defer g2.deinit();
    g2.disk_cache = &s2;
    g2.disk_compiler_build_id = 0xABCD;
    g2.disk_load_enabled = true;
    try g2.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 0), g2.disk_load_hits.load(.monotonic));
}

test "graph: load hit 게이트 — import.meta 모듈은 load OFF (#4438 ON==OFF)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // import.meta 는 cold 에서 has_module_syntax→exports_kind=.esm 로 만들지만, load 의
    // import_scanner 는 meta_property 를 안 봐 .none 으로 발산(require-target/entry/RN-wrap 에서
    // wrap_kind 차이). loadUnsafeSource 게이트로 cold parse 유지 → 캐시 있어도 load OFF(hit 0).
    try writeFile(tmp.dir, "index.mjs", "const u = import.meta.url; console.log(u);");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.mjs" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    {
        var s1 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
        defer s1.deinit();
        var c1 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer c1.deinit();
        var g1 = ModuleGraph.init(std.testing.allocator, &c1);
        defer g1.deinit();
        g1.disk_cache = &s1;
        g1.disk_compiler_build_id = 0xABCD;
        g1.disk_load_enabled = true;
        try g1.build(std.testing.io, &.{entry});
    }

    var s2 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer s2.deinit();
    var c2 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer c2.deinit();
    var g2 = ModuleGraph.init(std.testing.allocator, &c2);
    defer g2.deinit();
    g2.disk_cache = &s2;
    g2.disk_compiler_build_id = 0xABCD;
    g2.disk_load_enabled = true;
    try g2.build(std.testing.io, &.{entry});

    try std.testing.expectEqual(@as(usize, 0), g2.disk_load_hits.load(.monotonic));
}

test "graph: 진단 낸 모듈은 store skip → cache ON 2nd build 도 진단 재발행 (#4438 ON==OFF)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // import 바인딩 변형 → assign_to_import(ZNTC0805) error. AST/semantic 은 산출되어 store
    // 까지 도달하지만, 캐시하면 2nd build load hit 이 parse 를 스킵해 진단을 삼킨다(#4020 의도적
    // fatal 이 cache 로 사라짐). store skip 으로 위반 모듈은 항상 cold parse 되게 한 것을 가드.
    try writeFile(tmp.dir, "index.mjs", "import { a } from './a.mjs'; a = 1;");
    try writeFile(tmp.dir, "a.mjs", "export const a = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.mjs" });
    defer std.testing.allocator.free(entry);
    const cache_root = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "cache" });
    defer std.testing.allocator.free(cache_root);

    // 1st build: cold → 진단 emit + 위반 모듈 store skip(a.mjs 는 store 됨).
    var first_count: usize = undefined;
    {
        var s1 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
        defer s1.deinit();
        var c1 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
        defer c1.deinit();
        var g1 = ModuleGraph.init(std.testing.allocator, &c1);
        defer g1.deinit();
        g1.disk_cache = &s1;
        g1.disk_compiler_build_id = 0xABCD;
        g1.disk_load_enabled = true;
        try g1.build(std.testing.io, &.{entry});
        first_count = 0;
        for (g1.diagnostics.items) |d| {
            if (d.code == .assign_to_import and d.severity == .@"error") first_count += 1;
        }
        try std.testing.expect(first_count > 0); // 진단 존재 전제(소스가 실제로 트리거)
    }

    // 2nd build: a.mjs 는 load hit 되지만(캐시 동작 증명), 위반 모듈은 store 안 돼 cold parse → 진단 재발행.
    var s2 = try @import("disk_module_store.zig").DiskModuleStore.init(std.testing.allocator, cache_root);
    defer s2.deinit();
    var c2 = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer c2.deinit();
    var g2 = ModuleGraph.init(std.testing.allocator, &c2);
    defer g2.deinit();
    g2.disk_cache = &s2;
    g2.disk_compiler_build_id = 0xABCD;
    g2.disk_load_enabled = true;
    try g2.build(std.testing.io, &.{entry});

    try std.testing.expect(g2.disk_load_hits.load(.monotonic) > 0); // a.mjs load hit = 캐시 동작 증명
    var second_count: usize = 0;
    for (g2.diagnostics.items) |d| {
        if (d.code == .assign_to_import and d.severity == .@"error") second_count += 1;
    }
    // 핵심: cache ON 2nd build 도 1st 와 같은 진단 수(ON==OFF). store skip 없으면 0 으로 떨어진다.
    try std.testing.expectEqual(first_count, second_count);
}

test "CJS export source kind retains its parsed realm after a compiler import is appended" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "void 'compiler:helper';console.log(1);");
    const path = try dirPath(&tmp);
    defer std.testing.allocator.free(path);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ path, "entry.cjs" });
    defer std.testing.allocator.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const module = @constCast(graph.getModule(ModuleIndex.fromUsize(0)).?);
    try std.testing.expectEqual(types.ExportsKind.commonjs, module.exports_kind);
    const strict = module.semantic.?.scopes[0].is_strict;
    try std.testing.expect(!strict);
    const module_parameter = module.cjs_wrapper_module_parameter_symbol;
    const exports_parameter = module.cjs_wrapper_exports_parameter_symbol;
    try std.testing.expect(module_parameter != null and exports_parameter != null);
    const arena = module.parse_arena.?.allocator();
    const ast = &module.ast.?;
    const root = ast.transformed_root orelse @as(@import("../parser/ast.zig").NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    try std.testing.expect(ast.getNode(root).tag == .program);
    const old_list = ast.getNode(root).data.list;
    const statements = try arena.dupe(u32, ast.extra_data.items[old_list.start .. old_list.start + old_list.len]);
    var source_node: @import("../parser/ast.zig").NodeIndex = .none;
    for (ast.nodes.items, 0..) |node, index| {
        if (node.tag == .string_literal) {
            source_node = @fromBackingInt(@as(u32, @intCast(index)));
            break;
        }
    }
    try std.testing.expect(!source_node.isNone());
    const import_data = try ast.addExtras(&.{ 0, 0, @backingInt(source_node), 0, 0, 0 });
    const declaration = try ast.addNode(.{ .tag = .import_declaration, .span = .{ .start = 0, .end = 0 }, .data = .{ .extra = import_data } });
    const new_statements = try arena.alloc(@import("../parser/ast.zig").NodeIndex, statements.len + 1);
    new_statements[0] = declaration;
    for (statements, 1..) |raw, index| new_statements[index] = @fromBackingInt(raw);
    const new_list = try ast.addNodeList(new_statements);
    ast.nodes.items[@backingInt(root)].data.list = new_list;
    ast.transformed_root = root;
    const ids = try arena.alloc(?u32, ast.nodes.items.len);
    @memset(ids, null);
    @memcpy(ids[0..module.semantic.?.symbol_ids.len], module.semantic.?.symbol_ids);
    module.semantic.?.symbol_ids = ids;
    try @import("graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(&graph, module, arena);
    try std.testing.expectEqual(@as(usize, 1), module.import_records.len);
    try std.testing.expectEqualStrings("compiler:helper", module.import_records[0].specifier);
    try std.testing.expectEqual(types.ExportsKind.commonjs, module.exports_kind);
    try std.testing.expectEqual(types.WrapKind.cjs, module.wrap_kind);
    try std.testing.expectEqual(strict, module.semantic.?.scopes[0].is_strict);
    try std.testing.expectEqual(module_parameter, module.cjs_wrapper_module_parameter_symbol);
    try std.testing.expectEqual(exports_parameter, module.cjs_wrapper_exports_parameter_symbol);
}

test "CJS export source kind refresh uses the retained local receiver after a property edit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "function set(module){module.value=1;}set({});");
    const path = try dirPath(&tmp);
    defer std.testing.allocator.free(path);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ path, "entry.mjs" });
    defer std.testing.allocator.free(entry);
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const module = @constCast(graph.getModule(ModuleIndex.fromUsize(0)).?);
    try std.testing.expectEqual(types.ExportsKind.esm, module.exports_kind);
    const ast = &module.ast.?;
    var receiver: @import("../parser/ast.zig").NodeIndex = .none;
    for (ast.nodes.items) |node| {
        if (node.tag != .assignment_expression) continue;
        const lhs = ast.getNode(node.data.binary.left);
        if (lhs.tag != .static_member_expression) continue;
        receiver = ast.readExtraNode(lhs.data.extra, 0);
        const property = ast.readExtraNode(lhs.data.extra, 1);
        const name = try ast.addString("exports");
        ast.nodes.items[@backingInt(property)].span = name;
        ast.nodes.items[@backingInt(property)].data.string_ref = name;
        break;
    }
    try std.testing.expect(!receiver.isNone());
    const id = module.semantic.?.symbol_ids[@backingInt(receiver)].?;
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, module.semantic.?.symbols.items[id].kind);
    try @import("graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(&graph, module, module.parse_arena.?.allocator());
    try std.testing.expectEqual(types.ExportsKind.esm, module.exports_kind);
    try std.testing.expectEqual(id, module.semantic.?.symbol_ids[@backingInt(receiver)].?);
}
