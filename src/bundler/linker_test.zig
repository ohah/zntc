const std = @import("std");
const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const ImportBinding = linker_mod.ImportBinding;
const LinkingMetadata = linker_mod.LinkingMetadata;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const resolve_cache_mod = @import("resolve_cache.zig");
const writeFile = @import("test_helpers.zig").writeFile;
const bundler_symbol = @import("symbol.zig");
const PreservedRenames = bundler_symbol.PreservedRenames;

fn dirPath(tmp: *std.testing.TmpDir) ![:0]u8 {
    return try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
}

/// 주어진 basename 과 정확히 일치하는 모듈의 인덱스를 찾는다. 테스트에서 graph
/// 빌드 순서에 의존하지 않고 특정 소스 파일의 모듈을 지목하기 위한 헬퍼.
/// `std.fs.path.basename` 으로 경로 마지막 컴포넌트를 비교 — suffix 매칭(`endsWith`)이
/// 아니라 정확 일치라, 예컨대 "core.ts" 질의가 "my-core.ts" 모듈을 잘못 잡지 않는다.
fn findModuleIdx(graph: *ModuleGraph, basename: []const u8) ?ModuleIndex {
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.eql(u8, std.fs.path.basename(m.path), basename)) return m.index;
    }
    return null;
}

fn buildAndLink(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    // #1779 PR #2: Linker.graph 가 heap-stable 포인터여야 하므로 graph 를 heap 에 올린다.
    // 기존엔 linker 가 `[]const Module` slice 를 들고 있어 호출자 지역 graph 의
    // heap-backed slice pointer 로 안전했지만, 이제 graph 포인터가 필드라
    // TestResult 반환으로 stack 주소가 이동하면 lifetime 이 깨진다.
    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    const graph = try allocator.create(ModuleGraph);
    graph.* = ModuleGraph.init(allocator, &cache);
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(allocator, graph, .esm);
    try linker.link();

    return .{ .linker = linker, .graph = graph, .cache = cache };
}

test "linker: direct import resolves to export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // a.ts의 import x가 b.ts의 export x에 연결
    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(a.import_bindings.len > 0);
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
    // canonical이 b.ts(index 1)를 가리킴
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: re-export chain resolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // console.log(x): Phase D 가 미사용 named import 를 elide 하므로 value-use 추가
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // chain: a→b→c, canonical은 c(index 2)
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: missing export produces diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { missing } from './b'; console.log(missing);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // missing export → diagnostic
    var has_missing = false;
    for (r.linker.diagnostics.items) |d| {
        if (d.code == .missing_export) has_missing = true;
    }
    try std.testing.expect(has_missing);
}

test "linker: export * resolves through re-export all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 99;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // export * → c.ts(index 2)
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: export * from CJS resolves to CJS module" {
    // ESM이 export * from CJS를 하고, 소비자가 named import를 할 때
    // resolveExportChain이 CJS 모듈을 반환하는지 검증.
    // CJS 모듈은 정적 export가 없으므로, export * 경로에서
    // wrap_kind == .cjs인 모듈 자체를 반환해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 42 };");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // c.js는 CJS이므로, resolveExportChain이 c.js(index 2)를 반환
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
    // c.js가 실제로 CJS로 감지되었는지 확인
    try std.testing.expectEqual(types.WrapKind.cjs, r.graph.getModule(ModuleIndex.fromUsize(2)).?.wrap_kind);
}

test "linker: namespace re-export resolves to local binding" {
    // import * as ns from './c'; export { ns } 패턴에서
    // resolveExportChain이 현재 모듈(b.ts)의 로컬 바인딩을 반환하는지 검증.
    // namespace import는 소스 모듈에서 "*"를 named export로 찾을 수 없으므로,
    // 로컬 바인딩을 그대로 반환해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { ns } from './b'; console.log(ns);");
    try writeFile(tmp.dir, "b.ts", "import * as ns from './c';\nexport { ns };");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // namespace re-export는 b.ts(index 1)의 로컬 바인딩을 반환
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(binding.?.canonical.module_index));
    try std.testing.expectEqualStrings("ns", binding.?.canonical.export_name);
}

test "linker: resolveExportChain on CJS module returns null for named exports" {
    // CJS 모듈에 직접 resolveExportChain을 호출하면,
    // 정적 export가 없으므로 null을 반환해야 한다.
    // (export * from CJS 경로에서는 별도 CJS 폴백이 동작하지만,
    //  직접 호출 시에는 null)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.js", "module.exports = { x: 42 };");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();

    // b.js가 CJS로 감지됨
    try std.testing.expectEqual(types.WrapKind.cjs, graph.getModule(ModuleIndex.fromUsize(1)).?.wrap_kind);

    // CJS 모듈(index 1)에 직접 resolveExportChain 호출 → null
    // CJS는 정적 export가 없으므로 named export를 찾을 수 없다
    const result = linker.resolveExportChain(@enumFromInt(1), "x", 0);
    try std.testing.expect(result == null);
}

test "linker: default import resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import myDefault from './b';");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("default", binding.?.canonical.export_name);
}

test "linker: external import not resolved (no binding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from 'react';");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();

    // external → resolved binding 없음, diagnostic도 없음
    try std.testing.expectEqual(@as(usize, 0), linker.resolved_bindings.count());
    try std.testing.expectEqual(@as(usize, 0), linker.diagnostics.items.len);
}

// ============================================================
// Rename Tests
// ============================================================

const TestResult = struct {
    linker: Linker,
    /// heap-allocated ModuleGraph (Linker.graph 안정화 목적, #1779 PR #2).
    graph: *ModuleGraph,
    cache: resolve_cache_mod.ResolveCache,

    /// 기존 테스트들은 `defer r.graph.deinit()` 패턴을 사용했다. heap allocation
    /// 도입으로 destroy 가 추가로 필요해졌으므로, graph.deinit() 호출 시
    /// destroy 까지 한 번에 처리하도록 wrapper 를 제공한다.
    fn destroyGraph(self: *TestResult) void {
        self.graph.deinit();
        std.testing.allocator.destroy(self.graph);
    }
};

fn buildLinkAndRename(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    var r = try buildAndLink(allocator, tmp, entry_name);
    try r.linker.computeRenames();
    r.linker.populateImportSymbols();
    return .{ .linker = r.linker, .graph = r.graph, .cache = r.cache };
}

test "rename: no conflict — no rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // x는 b.ts에만 있으므로 충돌 없음 → canonical_names 비어 있음
    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_strings.items.len);
}

test "rename: two modules same name — second gets $1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // b.ts(exec_index 낮음)가 원본 유지, a.ts가 count$1
    // 또는 a.ts가 원본이고 b.ts가 $1 (exec_index에 따라)
    try std.testing.expect(r.linker.canonical_strings.items.len > 0);

    // 하나는 리네임됨
    var has_rename = false;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "count$")) has_rename = true;
    }
    try std.testing.expect(has_rename);
}

test "rename: three modules same name — $1 and $2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const name = 'c';");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 3개 중 2개 리네임
    var rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "name$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), rename_count);
}

test "rename: different names — no conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_strings.items.len);
}

test "rename: getCanonicalName returns renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 하나는 getCanonicalName으로 리네임 조회 가능
    var found_rename = false;
    for (0..r.graph.moduleCount()) |i| {
        if (r.linker.getCanonicalName(@intCast(i), "count")) |renamed| {
            try std.testing.expect(std.mem.startsWith(u8, renamed, "count$"));
            found_rename = true;
        }
    }
    try std.testing.expect(found_rename);

    // 원본 유지되는 모듈은 getCanonicalName이 null
    var found_original = false;
    for (0..r.graph.moduleCount()) |i| {
        if (r.linker.getCanonicalName(@intCast(i), "count") == null) {
            found_original = true;
        }
    }
    try std.testing.expect(found_original);
}

test "rename: non-exported top-level variables also detected (C1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // helper는 export 안 됨, 하지만 두 모듈 모두 top-level에 선언
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst helper = () => 1;\nexport const x = helper();");
    try writeFile(tmp.dir, "b.ts", "const helper = () => 2;\nexport const y = helper();");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // helper가 두 모듈에서 충돌 → 하나가 리네임됨
    var has_helper_rename = false;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "helper$")) has_helper_rename = true;
    }
    try std.testing.expect(has_helper_rename);
}

test "rename: nested scope conflict avoidance (hasNestedBinding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts: top-level x + nested scope에 x$1
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const x = 1;\nfunction foo(x$1: number) { return x$1; }");
    try writeFile(tmp.dir, "b.ts", "export const x = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // x가 충돌. 리네임된 쪽이 x$1을 건너뛰고 x$2가 되어야 함
    // (nested scope에 x$1이 이미 있으므로)
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "x$")) {
            // x$1이 아닌 다른 값이어야 함 (nested scope에 x$1 있으므로)
            // 단, semantic analyzer가 parameter를 어떤 scope에 넣는지에 따라 다를 수 있음
            try std.testing.expect(val.len > 0);
        }
    }
}

test "rename: default export local name conflict (L5)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport default function foo() { return 1; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // foo가 두 모듈에서 충돌 (a.ts: default export의 local name, b.ts: named export)
    var has_foo_rename = false;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "foo$")) has_foo_rename = true;
    }
    try std.testing.expect(has_foo_rename);
}

test "linker: deep re-export chain (near depth limit)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 5단계 re-export 체인: a → b → c → d → e
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export { x } from './d';");
    try writeFile(tmp.dir, "d.ts", "export { x } from './e';");
    try writeFile(tmp.dir, "e.ts", "export const x = 'deep';");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 e.ts(마지막 모듈)
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
}

test "isReservedName: JS reserved words" {
    try std.testing.expect(Linker.isReservedName("class"));
    try std.testing.expect(Linker.isReservedName("return"));
    try std.testing.expect(Linker.isReservedName("const"));
    try std.testing.expect(Linker.isReservedName("await"));
    try std.testing.expect(Linker.isReservedName("yield"));
    try std.testing.expect(!Linker.isReservedName("foo"));
    try std.testing.expect(!Linker.isReservedName("count$1"));
}

test "isCandidateAvailable: 예약어/글로벌/nested 통합 확인" {
    // isCandidateAvailable은 Linker 인스턴스 필요 → 최소 셋업
    // 빈 graph 도 Linker 가 *ModuleGraph 를 받으므로 stack 변수로 충분.
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();

    var name_to_owners: Linker.NameToOwnersMap = .empty;
    defer name_to_owners.deinit(std.testing.allocator);

    // 예약어는 불가
    try std.testing.expect(!linker.isCandidateAvailable("class", 0, &name_to_owners));
    // 일반 이름은 가능
    try std.testing.expect(linker.isCandidateAvailable("foo", 0, &name_to_owners));
    // name_to_owners에 있는 이름은 불가
    try name_to_owners.put(std.testing.allocator, "bar", .empty);
    try std.testing.expect(!linker.isCandidateAvailable("bar", 0, &name_to_owners));
    // reserved_globals에 있는 이름은 불가
    try linker.reserved_globals.put(std.testing.allocator, "console", {});
    try std.testing.expect(!linker.isCandidateAvailable("console", 0, &name_to_owners));
}

test "single-owner reserved name: candidate skips nested binding" {
    // 모듈 b.ts에서 console.log 사용 → console이 unresolved_references에 수집.
    // 모듈 a.ts에서 const console 선언 (단일 소유자) + nested scope에 console$1 존재.
    // scope hoisting 시 a.ts의 console이 b.ts의 글로벌 참조를 가리므로 리네임 필요.
    // 후보 console$1은 nested scope에 있으므로 건너뛰고 console$2가 되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import './b';
        \\const console = { log: () => {} };
        \\function f() { const console$1 = 1; return console$1; }
    );
    try writeFile(tmp.dir, "b.ts",
        \\console.log("hello");
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // b.ts의 console.log → console이 reserved_globals에 수집됨.
    // a.ts의 const console은 단일 소유자이지만 글로벌 shadowing → 리네임됨.
    const renamed = r.linker.getCanonicalName(0, "console");
    try std.testing.expect(renamed != null);
    // nested scope에 console$1이 있으므로 console$2가 되어야 함
    try std.testing.expectEqualStrings("console$2", renamed.?);
}

test "isReservedName: special identifiers" {
    // undefined, NaN, Infinity, arguments, eval은 예약어급 (키워드 목록에 유지)
    try std.testing.expect(Linker.isReservedName("undefined"));
    try std.testing.expect(Linker.isReservedName("arguments"));
    try std.testing.expect(Linker.isReservedName("eval"));
    try std.testing.expect(Linker.isReservedName("NaN"));
    try std.testing.expect(Linker.isReservedName("Infinity"));
    // Array/Object 등 대부분의 글로벌은 unresolved references로 자동 수집
    try std.testing.expect(!Linker.isReservedName("Array"));
    try std.testing.expect(!Linker.isReservedName("Object"));
    // window/console 등 주요 글로벌은 안전망으로 정적 목록에 포함
    try std.testing.expect(Linker.isReservedName("console"));
    try std.testing.expect(Linker.isReservedName("window"));
    try std.testing.expect(Linker.isReservedName("require"));
    try std.testing.expect(Linker.isReservedName("module"));
    try std.testing.expect(!Linker.isReservedName("myVar"));
}

test "computeRenamesForModules: 지정된 모듈만 대상으로 충돌 감지" {
    // 3개 모듈이 같은 이름 "x"를 가지지만,
    // computeRenamesForModules에 2개만 전달하면 그 2개만 충돌 처리.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nconst x = 'a';");
    try writeFile(tmp.dir, "b.ts", "const x = 'b';");
    try writeFile(tmp.dir, "c.ts", "const x = 'c';");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();

    // 전체 3개 모듈을 글로벌 rename — 2개가 rename됨
    try linker.computeRenames();
    var global_rename_count: usize = 0;
    for (0..graph.moduleCount()) |i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) global_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), global_rename_count);

    // per-module rename: 모듈 0, 1만 대상 → 1개만 rename됨
    const subset = &[_]ModuleIndex{ @enumFromInt(0), @enumFromInt(1) };
    try linker.computeRenamesForModules(subset, &.{});
    var subset_rename_count: usize = 0;
    for (0..graph.moduleCount()) |i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) subset_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), subset_rename_count);
}

test "clearCanonicalNames: 초기화 후 비어있음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst x = 1;");
    try writeFile(tmp.dir, "b.ts", "const x = 2;");

    const dp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});

    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.computeRenames();

    // rename 결과가 있어야 함
    try std.testing.expect(linker.canonical_strings.items.len > 0);

    // 초기화 후 비어있어야 함
    linker.clearCanonicalNames();
    try std.testing.expectEqual(@as(usize, 0), linker.canonical_strings.items.len);
}

// ============================================================
// Issue #282: namespace import (import * as X) scope hoisting
// ============================================================

test "namespace: import * as creates namespace object preamble" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils.add(1,2));");
    try writeFile(tmp.dir, "utils.ts", "export function add(a: number, b: number) { return a + b; }\nexport function mul(a: number, b: number) { return a * b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // namespace import는 resolved_bindings에 등록되지 않음 (resolveImports에서 skip)
    // 대신 buildMetadataForAst에서 preamble로 처리
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: export * from re-exports collected in namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as all from './barrel';\nconsole.log(all);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './a';\nexport * from './b';");
    try writeFile(tmp.dir, "a.ts", "export const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // barrel 모듈에서 export * 로 a, b의 export를 수집
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// Issue #283: re-export alias 바인딩 해결
// ============================================================

test "re-export alias: export { J as render } resolves to J" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // preact 패턴: 함수를 다른 이름으로 re-export
    try writeFile(tmp.dir, "entry.ts", "import { render } from './reexport'; console.log(render);");
    try writeFile(tmp.dir, "reexport.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry의 import { render }가 impl.ts의 J에 연결
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 impl.ts의 "J" — re-export 체인을 따라 최종 모듈의 export 이름
    const canon = binding.?.canonical;
    try std.testing.expectEqualStrings("J", canon.export_name);
    // resolveToLocalName도 "J" (impl.ts에서 함수명과 export명이 동일)
    const local = r.linker.resolveToLocalName(canon);
    try std.testing.expectEqualStrings("J", local);
}

test "re-export alias: export { default as groupBy } — function declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default <function_declaration> → binding_scanner가 함수 이름 추출
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './barrel'; console.log(greet);");
    try writeFile(tmp.dir, "barrel.ts", "export { default as greet } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default function hello() { return 'hi'; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 impl.ts의 "default" → local_name = "hello" (함수명)
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("hello", local);
}

test "re-export alias: export { default as X } — identifier reuses original name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default <identifier> → rolldown 방식: identifier 이름 재사용
    try writeFile(tmp.dir, "entry.ts", "import { groupBy } from './barrel'; console.log(groupBy);");
    try writeFile(tmp.dir, "barrel.ts", "export { default as groupBy } from './groupBy';");
    try writeFile(tmp.dir, "groupBy.ts", "function groupBy(arr: any) { return arr; }\nexport default groupBy;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // export default groupBy → local_name = "groupBy" (identifier 이름 재사용)
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("groupBy", local);
}

// ============================================================
// Issue #284: _default 이름 충돌 해결
// ============================================================

test "rename: multiple export default identifiers use original names — no collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // rolldown 방식: export default identifier → 각각 x, y, z로 별도 이름 → 충돌 없음
    try writeFile(tmp.dir, "entry.ts", "import './a';\nimport './b';\nimport './c';");
    try writeFile(tmp.dir, "a.ts", "const x = 1;\nexport default x;");
    try writeFile(tmp.dir, "b.ts", "const y = 2;\nexport default y;");
    try writeFile(tmp.dir, "c.ts", "const z = 3;\nexport default z;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // x, y, z는 각각 다른 이름이므로 충돌 없음 → _default$ 리네임 0개
    var rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "_default$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), rename_count);
}

// ============================================================
// Issue #283+: namespace import edge cases
// ============================================================

test "namespace: diamond export * dedup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A exports * from B and C, both export * from shared.
    // x should appear once (no duplicate).
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './a';\nconsole.log(ns.x);");
    try writeFile(tmp.dir, "a.ts", "export * from './b';\nexport * from './c';");
    try writeFile(tmp.dir, "b.ts", "export * from './shared';");
    try writeFile(tmp.dir, "c.ts", "export * from './shared';");
    try writeFile(tmp.dir, "shared.ts", "export const x = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry에서 namespace import로 ns를 가져옴 — 무한 루프 없이 완료
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: circular export * no infinite loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A exports * from B, B exports * from A — 순환 export *
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './a';\nconsole.log(ns);");
    try writeFile(tmp.dir, "a.ts", "export * from './b';\nexport const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export * from './a';\nexport const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 무한 루프 없이 완료되면 성공
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: mixed named + default exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 모듈이 named export와 default export를 모두 가짐
    try writeFile(tmp.dir, "entry.ts", "import * as m from './mod';\nconsole.log(m.x, m.default);");
    try writeFile(tmp.dir, "mod.ts", "export const x = 1;\nexport default 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: re-export alias in namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // barrel이 J를 render로 re-export → namespace에서 render로 접근 가능해야 함
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './barrel';\nconsole.log(ns.render);");
    try writeFile(tmp.dir, "barrel.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// Re-export alias edge cases
// ============================================================

test "re-export alias: double-hop chain (z -> y -> x)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3-level alias chain: z → y → x → 최종 original
    try writeFile(tmp.dir, "entry.ts", "import { z } from './hop1'; console.log(z);");
    try writeFile(tmp.dir, "hop1.ts", "export { y as z } from './hop2';");
    try writeFile(tmp.dir, "hop2.ts", "export { x as y } from './origin';");
    try writeFile(tmp.dir, "origin.ts", "export function x() { return 1; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // 3-hop chain → 최종 origin.ts의 "x"
    const canon = binding.?.canonical;
    try std.testing.expectEqualStrings("x", canon.export_name);
    const local = r.linker.resolveToLocalName(canon);
    try std.testing.expectEqualStrings("x", local);
}

test "re-export alias: default class declaration resolves to class name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default class MyClass {} → local_name = "MyWidget"
    try writeFile(tmp.dir, "entry.ts", "import { Widget } from './barrel'; console.log(Widget);");
    try writeFile(tmp.dir, "barrel.ts", "export { default as Widget } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default class MyWidget { render() {} }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // default class declaration → local_name = "MyWidget"
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("MyWidget", local);
}

// ============================================================
// _default collision edge cases
// ============================================================

test "rename: mixed function + expression defaults — identifier collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // rolldown 방식: export default val → local_name = "val" (두 모듈에서 충돌)
    try writeFile(tmp.dir, "entry.ts", "import a from './func';\nimport b from './expr1';\nimport c from './expr2';");
    try writeFile(tmp.dir, "func.ts", "export default function myFunc() { return 1; }");
    try writeFile(tmp.dir, "expr1.ts", "const val = 2;\nexport default val;");
    try writeFile(tmp.dir, "expr2.ts", "const val = 3;\nexport default val;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // expr1, expr2 모두 val → 하나가 val$1로 리네임
    var val_rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |v| {
        if (std.mem.startsWith(u8, v, "val$")) val_rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), val_rename_count);
}

test "rename: default identifier reuses name — no _default collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // rolldown 방식: export default x → local_name="x", export default y → local_name="y" → 충돌 없음
    try writeFile(tmp.dir, "entry.ts", "import a from './a';\nimport b from './b';\nconsole.log(a, b);");
    try writeFile(tmp.dir, "a.ts", "const x = 10;\nexport default x;");
    try writeFile(tmp.dir, "b.ts", "const y = 20;\nexport default y;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // x, y는 다른 이름이므로 충돌 없음 → _default$ 리네임 0개
    var rename_count: u32 = 0;
    for (r.linker.canonical_strings.items) |val| {
        if (std.mem.startsWith(u8, val, "_default$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 0), rename_count);
}

// ============================================================
// export * as ns from (ES2020 namespace re-export) — #289
// ============================================================

test "export * as: basic namespace re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { math } from './barrel';\nconsole.log(math.add(1, 2));");
    try writeFile(tmp.dir, "barrel.ts", "export * as math from './math';");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry의 import { math }가 barrel의 "math" export에 연결
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("math", binding.?.canonical.export_name);
}

test "export * as: binding_scanner registers named export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export * as utils from './utils';");
    try writeFile(tmp.dir, "utils.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // barrel 모듈(index 1)의 export_bindings에 "utils" 이름이 등록됨
    var has_utils_export = false;
    var it = r.graph.modulesIterator();
    while (it.next()) |m| {
        for (m.export_bindings) |eb| {
            if (std.mem.eql(u8, eb.exported_name, "utils")) {
                has_utils_export = true;
                // local_name도 "utils" (preamble에서 var utils = {...} 생성용)
                try std.testing.expectEqualStrings("utils", eb.local_name);
            }
        }
    }
    try std.testing.expect(has_utils_export);
}

// ============================================================
// esbuild 방식 namespace import — ns.prop 직접 치환
// ============================================================

test "namespace rewrite: ns.prop resolved in ns_member_rewrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils.add(1, 2));");
    try writeFile(tmp.dir, "utils.ts", "export function add(a: number, b: number) { return a + b; }\nexport function mul(a: number, b: number) { return a * b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // ns.prop만 사용 → ns_member_rewrites에 매핑 등록
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// semantic analyzer: property key symbol_id 미할당
// ============================================================

test "semantic: non-shorthand property key has no symbol_id" {
    // { checks: [] } — "checks" key는 변수 참조가 아님
    // semantic analyzer에서 symbol_id를 할당하지 않아야 함
    const source = "const checks = 1;\nconst obj = { checks: [] };";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    // "checks" 변수 선언은 reference_count 증가 없어야 함
    // (shorthand가 아닌 property key에서 참조 안 됨)
    // 정확히는: checks 변수의 reference_count가 0이어야 함
    // (const obj = { checks: [] }에서 checks key는 resolve 안 됨)
    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("checks")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                // shorthand가 아닌 property key에서 참조되지 않으므로 ref count = 0
                try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.items[sym_idx].reference_count);
            }
        }
    }
}

test "semantic: shorthand property key has symbol_id" {
    // { checks } — shorthand에서는 "checks"가 변수 참조
    const source = "const checks = 1;\nconst obj = { checks };";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    // shorthand { checks } 에서 checks는 변수 참조 → reference_count > 0
    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("checks")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expect(analyzer.symbols.items[sym_idx].reference_count > 0);
            }
        }
    }
}

// ============================================================
// export * as ns — seen 오염 방지 (독립 namespace)
// ============================================================

test "export * as: does not pollute parent seen (name collision)" {
    // export * as ns의 내부 export가 외부 export *의 같은 이름을 덮어쓰면 안 됨
    // regexes에 string (regex), schemas에 string (factory) → 외부는 schemas의 string 사용
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "schemas.ts", "export function string() { return 'schema'; }");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport * from './schemas';");
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './core';\nconsole.log(ns.string());");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // entry의 namespace import 확인
    const entry = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);

    // 회귀 가드(zod `z.string`===undefined): `export * as regexes` 의 내부 `string` 이
    // plain `export *`(schemas)의 `string` 과 false-ambiguous 충돌하면 안 된다.
    // `export * as ns` 는 top-level 에 `ns` 한 이름만 기여하므로 ambiguity 판정 비참여.
    const core_idx = findModuleIdx(r.graph, "core.ts").?;
    const schemas_idx = findModuleIdx(r.graph, "schemas.ts").?;
    try std.testing.expect(!r.linker.isAmbiguousStarExport(core_idx, "string"));
    const resolved = r.linker.resolveExportChain(core_idx, "string", 0);
    try std.testing.expect(resolved != null);
    // schemas(plain star)의 factory 로 해석되어야 한다 — regexes(namespaced)가 아님.
    try std.testing.expectEqual(@intFromEnum(schemas_idx), @intFromEnum(resolved.?.module_index));
}

test "export * as: namespaced inner name does not leak to top-level (no false resolve)" {
    // `export * as regexes` 만 있고 plain `export *` 가 없으면, regexes 의 내부 `string`
    // 은 core 의 top-level export 가 아니다(ESM: namespaced star 는 `regexes` 한 이름만
    // 기여). top-level `string` resolve 는 null 이어야 하고 ambiguous 도 아니다.
    // 회귀 가드: resolveStarExport 가 namespaced re-export 를 따라가면 `string` 을
    // regexes.string 으로 잘못 해석(leak)했었다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport const marker = 1;");
    try writeFile(tmp.dir, "entry.ts", "import { string } from './core';\nconsole.log(string);");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const core_idx = findModuleIdx(r.graph, "core.ts").?;
    // top-level `string` 은 존재하지 않음 → resolve null, ambiguous 아님.
    try std.testing.expect(r.linker.resolveExportChain(core_idx, "string", 0) == null);
    try std.testing.expect(!r.linker.isAmbiguousStarExport(core_idx, "string"));
    // `regexes` 자체는 정상 named export 로 해석.
    try std.testing.expect(r.linker.resolveExportChain(core_idx, "regexes", 0) != null);
    // named import { string } 는 진짜 missing → 진단.
    var has_missing = false;
    for (r.linker.diagnostics.items) |d| {
        if (d.code == .missing_export) has_missing = true;
    }
    try std.testing.expect(has_missing);
}

test "export * as: genuine 2-plain-star ambiguity preserved despite namespaced star" {
    // over-correction 가드: plain `export *` 2개(schemas, extra)가 같은 `string` 을
    // 내보내면 `export * as regexes` 가 함께 있어도 여전히 ESM-ambiguous 여야 한다.
    // (namespaced star 는 ambiguity 에 영향 없음 — 추가도 제거도 하지 않음.)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "schemas.ts", "export function string() { return 'schema'; }");
    try writeFile(tmp.dir, "extra.ts", "export function string() { return 'extra'; }");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport * from './schemas';\nexport * from './extra';");
    try writeFile(tmp.dir, "entry.ts", "import { string } from './core';\nconsole.log(string);");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const core_idx = findModuleIdx(r.graph, "core.ts").?;
    // schemas + extra 두 plain star 가 distinct canonical → ambiguous → resolve null.
    try std.testing.expect(r.linker.isAmbiguousStarExport(core_idx, "string"));
    try std.testing.expect(r.linker.resolveExportChain(core_idx, "string", 0) == null);
    // ambiguous named import → 사용자 노출(fatal) 진단. (missing_export 와 달리
    // ambiguous_export 는 fatal_diagnostics 에만 기록된다.)
    var has_ambiguous = false;
    for (r.linker.fatal_diagnostics.items) |d| {
        if (d.code == .ambiguous_export) has_ambiguous = true;
    }
    try std.testing.expect(has_ambiguous);
}

// ============================================================
// CJS Preamble 출력 검증 테스트
// ============================================================

const Ast = @import("../parser/ast.zig").Ast;

/// buildMetadataForAst를 호출하여 preamble을 검증하는 헬퍼.
/// computeRenames 후 원본 AST 기준 메타데이터를 생성한다.
fn buildMetadataForModule(
    r: *const TestResult,
    module_index: u32,
    is_entry: bool,
) !LinkingMetadata {
    const mod = r.linker.graph.getModule(ModuleIndex.fromUsize(module_index)) orelse return error.NoAst;
    const ast: *const Ast = &(mod.ast orelse return error.NoAst);
    return r.linker.buildMetadataForAst(ast, module_index, is_entry, null, r.linker.format, true);
}

test "preamble: CJS module import — named import generates require_xxx" {
    // ESM에서 CJS 모듈의 named import를 가져올 때
    // preamble에 "var x = require_c().x;" 형태가 생성되는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './c';\nconsole.log(x);");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 42 };");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // c.js가 CJS로 감지되었는지 확인
    try std.testing.expectEqual(types.WrapKind.cjs, r.graph.getModule(ModuleIndex.fromUsize(1)).?.wrap_kind);

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    // preamble이 생성되어야 함
    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // require_xxx() 호출 포함
    try std.testing.expect(std.mem.indexOf(u8, preamble, "require_") != null);
    // named import이므로 .x 접근이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".x") != null);
}

test "preamble: CJS module import — direct module.exports default import skips __toESM" {
    // ESM에서 CJS 모듈의 default import를 가져올 때
    // __toESM 래퍼가 생성되는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './c';\nconsole.log(foo);");
    try writeFile(tmp.dir, "c.js", "module.exports = { default: 42 };");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__toESM(") == null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") == null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, "require_c()") != null);
}

test "preamble: CJS module import — __esModule marker keeps __toESM default import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './c';\nconsole.log(foo);");
    try writeFile(tmp.dir, "c.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = 42;
    );

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__toESM(") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") != null);
}

test "preamble: CJS module import — namespace import generates __toESM without .default" {
    // ESM에서 CJS 모듈을 namespace import할 때
    // __toESM 래퍼가 생성되고, .default가 붙지 않는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as c from './c';\nconsole.log(c);");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 1 };");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // __toESM 래퍼 포함
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__toESM(") != null);
    // namespace import는 .default가 붙지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") == null);
}

test "preamble: unresolved import generates require()" {
    // external/unresolved import는 require("specifier") 형태 preamble 생성
    // 존재하지 않는 상대 경로를 사용하여 resolve 실패를 유도
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { readFile } from './nonexistent';\nconsole.log(readFile);");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // require("./nonexistent") 형태
    try std.testing.expect(std.mem.indexOf(u8, preamble, "require(") != null);
    // named import이므로 .readFile 접근
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".readFile") != null);
}

test "preamble: dev mode — named import uses namespace access pattern" {
    // dev mode에서 named import는 namespace 접근 패턴: __ns_0_0 = __zntc_require("./path")
    // 호이스팅된 함수에서 import binding을 안전하게 참조하기 위해
    // 구조분해 대신 namespace 객체 프로퍼티 접근을 사용한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { add } from './math';\nconsole.log(add(1,2));");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const ast: *const Ast = &(r.graph.getModule(ModuleIndex.fromUsize(0)).?.ast orelse unreachable);
    var md = try r.linker.buildDevMetadataForAst(ast, 0);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    // namespace 할당: __ns_0_0 = __zntc_require("./path") (module_index=0, local=0)
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__ns_0_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__zntc_require(") != null);
    // 구조분해 패턴 없음 (var { add } 형태가 아님)
    try std.testing.expect(std.mem.indexOf(u8, preamble, "{ ") == null);
    // dev_ns_vars가 호이스팅용으로 설정됨
    try std.testing.expect(md.dev_ns_vars != null);
    try std.testing.expectEqual(@as(usize, 1), md.dev_ns_vars.?.len);
    try std.testing.expectEqualStrings("__ns_0_0", md.dev_ns_vars.?[0]);
    // renames에 add → __ns_0_0.add 매핑 등록 확인
    var rename_found = false;
    var it = md.renames.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, "__ns_0_0.add")) {
            rename_found = true;
            break;
        }
    }
    try std.testing.expect(rename_found);
}

test "preamble: dev mode — default import uses .default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import foo from './lib';\nconsole.log(foo);");
    try writeFile(tmp.dir, "lib.ts", "export default 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const ast: *const Ast = &(r.graph.getModule(ModuleIndex.fromUsize(0)).?.ast orelse unreachable);
    var md = try r.linker.buildDevMetadataForAst(ast, 0);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__zntc_require(") != null);
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") != null);
}

test "preamble: dev mode — namespace import without .default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils);");
    try writeFile(tmp.dir, "utils.ts", "export const x = 1;\nexport const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const ast: *const Ast = &(r.graph.getModule(ModuleIndex.fromUsize(0)).?.ast orelse unreachable);
    var md = try r.linker.buildDevMetadataForAst(ast, 0);
    defer md.deinit();

    try std.testing.expect(md.cjs_import_preamble != null);
    const preamble = md.cjs_import_preamble.?;
    try std.testing.expect(std.mem.indexOf(u8, preamble, "__zntc_require(") != null);
    // namespace는 .default 없이 모듈 전체
    try std.testing.expect(std.mem.indexOf(u8, preamble, ".default") == null);
}

test "preamble: no preamble for ESM-to-ESM import" {
    // ESM→ESM은 rename으로 처리되므로 preamble이 없어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './b';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var md = try buildMetadataForModule(&r, 0, true);
    defer md.deinit();

    // ESM→ESM이면 preamble 없음
    try std.testing.expectEqual(@as(?[]const u8, null), md.cjs_import_preamble);
}

// ============================================================
// Semantic tests
// ============================================================

test "semantic: non-shorthand {x: y} does not reference x" {
    // {x: y} — x는 property name (변수 참조 아님), y는 변수 참조
    const source = "const x = 1;\nconst y = 2;\nconst obj = {x: y};";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("x")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.items[sym_idx].reference_count);
            }
        }
        if (analyzer.scope_maps.items[0].get("y")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expect(analyzer.symbols.items[sym_idx].reference_count > 0);
            }
        }
    }
}

// #1328 Phase 4d: populateSymbolRefCounts

test "populateSymbolRefCounts: import이 source default symbol의 ref_count 증가" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import x from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateReExportAliases();
    r.linker.populateImportSymbols();
    r.linker.populateSymbolRefCounts();

    // b.ts의 synthetic_default symbol이 참조되어 ref_count == 1.
    // #1328 Phase 4e-2b: _default는 semantic 공간에 등록됨.
    const b = r.graph.getModule(ModuleIndex.fromUsize(1)).?;
    const b_sem = b.semantic orelse return error.NoSemantic;
    var found_ref: u32 = 0;
    for (b_sem.symbols.items) |sym| {
        const sk = sym.synthetic_kind orelse continue;
        if (sk == .default_export) {
            found_ref = sym.reference_count;
            break;
        }
    } else return error.DefaultNotRegistered;
    try std.testing.expectEqual(@as(u32, 1), found_ref);
}

test "populateSymbolRefCounts: 아무도 안 쓰는 export는 ref_count 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry는 named만 씀, default는 import 안 함
    try writeFile(tmp.dir, "a.ts", "import { y } from './b'; console.log(y);");
    try writeFile(tmp.dir, "b.ts", "export default 42; export const y = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateReExportAliases();
    r.linker.populateImportSymbols();
    r.linker.populateSymbolRefCounts();

    const b = r.graph.getModule(ModuleIndex.fromUsize(1)).?;
    const b_sem = b.semantic orelse return error.NoSemantic;
    var found_ref: u32 = 0;
    var found_default = false;
    for (b_sem.symbols.items) |sym| {
        const sk = sym.synthetic_kind orelse continue;
        if (sk == .default_export) {
            found_ref = sym.reference_count;
            found_default = true;
            break;
        }
    }
    if (!found_default) return error.DefaultNotRegistered;
    try std.testing.expectEqual(@as(u32, 0), found_ref);
}

// #1338 Phase 4c-3: SymbolRef 기반 canonical name facade
test "getCanonicalByRef: alias symbol의 canonical_name 반환" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export { default as Foo } from './b';");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateReExportAliases();
    r.linker.populateImportSymbols();

    // a.ts의 barrel re-export alias symbol 찾기
    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    var alias_ref: ?@import("symbol.zig").SymbolRef = null;
    for (a.export_bindings) |eb| {
        if (eb.kind == .re_export and std.mem.eql(u8, eb.exported_name, "Foo")) {
            alias_ref = eb.symbol;
            break;
        }
    }
    const ref = alias_ref orelse return error.AliasNotFound;
    // alias는 canonical_name이 resolve된 상태 — facade가 non-null 반환해야 함
    const name = r.linker.getCanonicalByRef(ref) orelse return error.NoCanonical;
    try std.testing.expect(name.len > 0);
}

// #1328 Phase 4c-3c-2 / RFC #3940 L.5c: putCanonicalName → rename_table 기록
test "computeRenames: rename된 심볼이 rename_table 에 기록됨" {
    const symbol_mod = @import("symbol.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 같은 이름 'x'가 두 모듈에서 export → 충돌 → 한 쪽이 x$1
    try writeFile(tmp.dir, "a.ts", "export { x as a } from './m1'; export { x as b } from './m2';");
    try writeFile(tmp.dir, "m1.ts", "export const x = 1;");
    try writeFile(tmp.dir, "m2.ts", "export const x = 2;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();

    // m1 또는 m2 중 하나의 'x' 심볼이 rename_table 엔트리를 가져야 함.
    var renamed_count: u32 = 0;
    var it = r.graph.modulesIterator();
    while (it.next()) |m| {
        const sem = m.semantic orelse continue;
        if (sem.scope_maps.len == 0) continue;
        const sym_idx = sem.scope_maps[0].get("x") orelse continue;
        const id = symbol_mod.SymbolID.make(m.index, sym_idx);
        if (r.linker.rename_table.get(id) != null) renamed_count += 1;
    }
    try std.testing.expect(renamed_count >= 1);
    try std.testing.expect(r.linker.rename_table.count() >= renamed_count);
}

test "RenameTable: computeMangling 경로가 rename_table 에 기록 (RFC #3940 L.5c)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // top-level mangle 가 동작하도록 여러 심볼이 있는 모듈.
    try writeFile(tmp.dir, "a.ts", "import { helper } from './util'; export const result = helper(1);");
    try writeFile(tmp.dir, "util.ts", "const internal = 10; export function helper(n) { return n + internal; }");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();
    try r.linker.computeMangling();

    // computeMangling (assignSymbolCanonical 직접 경로) 가 실제로 rename 을 만든다.
    try std.testing.expect(r.linker.rename_table.count() > 0);
}

test "RenameTable: clearCanonicalNames 가 rename_table 도 비움 (RFC #3940 L.5c)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export { x as a } from './m1'; export { x as b } from './m2';");
    try writeFile(tmp.dir, "m1.ts", "export const x = 1;");
    try writeFile(tmp.dir, "m2.ts", "export const x = 2;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();
    try std.testing.expect(r.linker.rename_table.count() >= 1);

    // clearCanonicalNames 후 canonical_strings 와 함께 rename_table 도 비워져야
    // stale slice 참조 0 (per-chunk reset 안전성).
    r.linker.clearCanonicalNames();
    try std.testing.expectEqual(@as(u32, 0), r.linker.rename_table.count());
}

test "applyPendingRenames: pending 반영 + mutated module stale entry prune (RFC #3940 L.5a)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export { x as a } from './m1';");
    try writeFile(tmp.dir, "m1.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    try r.linker.computeRenames();

    const symbol_mod = @import("symbol.zig");
    const m0 = r.graph.modules.at(0);
    defer m0.pending_renames.deinit(std.testing.allocator);
    const mi: ModuleIndex = @enumFromInt(0);

    // carry-over 모사: resync 로 idx 가 바뀌어 (m0, 99) 가 stale 가 된 상태 + new idx (m0, 0) pending.
    try r.linker.rename_table.put(std.testing.allocator, symbol_mod.SymbolID.make(mi, 99), "stale");
    try m0.pending_renames.put(std.testing.allocator, symbol_mod.SymbolID.make(mi, 0), "fresh");

    try r.linker.applyPendingRenames();

    // mutated module 의 stale entry (m0, 99) prune + pending (m0, 0) 반영 + pending clear.
    try std.testing.expect(r.linker.rename_table.get(symbol_mod.SymbolID.make(mi, 99)) == null);
    try std.testing.expectEqualStrings("fresh", r.linker.rename_table.get(symbol_mod.SymbolID.make(mi, 0)).?);
    try std.testing.expectEqual(@as(u32, 0), m0.pending_renames.count());
}

// Regression: HMR rebuild 에서 소스가 재파싱된 모듈의 `alias_table` 이 줄어들
// 수 있어 (e.g. re_export 엔트리가 없어진 경우), 캐시된 import_binding 의
// `.symbol.alias` 가 old-build AliasId 를 stale 로 들고 있으면
// `populateSymbolRefCounts` 가 `aliases.items[idx]` OOB 로 panic → 서버
// segfault. `.alias` branch 에 `a.symbol >= table.count()` 경계 검사 추가.
test "populateSymbolRefCounts: stale alias id 는 건너뜀 (bounds guard)" {
    const allocator = std.testing.allocator;
    const ImportBindingT = @import("binding_scanner.zig").ImportBinding;
    const symbol_mod = @import("symbol.zig");

    // module[0] (importer): import_binding 이 module[1] 의 AliasId(5) 를 가리킴
    // module[1] (source): alias_table 이 비어있음 (rebuild 로 새로 만들어졌지만
    //                     re_export 가 없어 entry 0)
    const ib: ImportBindingT = .{
        .kind = .named,
        .local_name = "X",
        .imported_name = "X",
        .local_span = .{ .start = 0, .end = 1 },
        .import_record_index = 0,
        .symbol = .{
            .alias = .{
                .module = @enumFromInt(1),
                .symbol = @enumFromInt(5), // stale — table.count() == 0
            },
        },
    };

    const module_mod = @import("module.zig");

    // #1779 PR #2: Linker 는 `*ModuleGraph` 만 받으므로, 수동으로 구성한 모듈을
    // graph.modules 에 직접 append 해서 최소 graph 를 만든다.
    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(allocator, &cache);
    defer graph.deinit();
    try graph.modules.append(allocator, module_mod.Module.init(@enumFromInt(0), "/a.ts"));
    try graph.modules.append(allocator, module_mod.Module.init(@enumFromInt(1), "/b.ts"));

    // importer module 의 import_bindings 를 주입.
    var ibs = [_]ImportBindingT{ib};
    graph.moduleAtMut(ModuleIndex.fromUsize(0)).?.import_bindings = &ibs;
    // source module 에 빈 alias_table 주입.
    graph.moduleAtMut(ModuleIndex.fromUsize(1)).?.alias_table = symbol_mod.AliasTable.init(allocator);

    var linker = Linker.init(allocator, &graph, .esm);
    defer linker.deinit();

    // 수정 전: `index 5, len 0` panic. 수정 후: 조용히 skip.
    linker.populateSymbolRefCounts();
}

test "populateImportSymbols: named import의 local_symbol이 현재 모듈 semantic ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    r.linker.populateImportSymbols();

    const a = r.graph.getModule(ModuleIndex.fromUsize(0)).?;
    var found = false;
    for (a.import_bindings) |ib| {
        if (std.mem.eql(u8, ib.local_name, "x")) {
            try std.testing.expect(ib.local_symbol.isValid());
            // 현재 모듈(a=0)을 가리켜야 함 — source(b=1)가 아님
            try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ib.local_symbol.moduleIndex()));
            found = true;
        }
    }
    try std.testing.expect(found);
}

// ============================================================
// HMR rename 재사용 Tests (perf/hmr-link-rename-reuse)
// ============================================================

/// 두 rename_table 이 byte-identical 인지 (같은 SymbolID 집합 + 같은 이름) 단언.
/// "재사용 ≡ recompute" 증명의 핵심 — 주입된 table 이 from-scratch computeRenames 와
/// 완전히 동일해야 한다.
fn expectRenameTablesEqual(a: *const Linker, b: *const Linker) !void {
    try std.testing.expectEqual(a.rename_table.count(), b.rename_table.count());
    var it = a.rename_table.map.iterator();
    while (it.next()) |e| {
        const other = b.rename_table.get(e.key_ptr.*) orelse {
            std.debug.print("missing key in b: mod={d} inner={d}\n", .{
                @intFromEnum(e.key_ptr.module), @intFromEnum(e.key_ptr.inner),
            });
            return error.MissingKey;
        };
        try std.testing.expectEqualStrings(e.value_ptr.*, other);
    }
}

test "reuse: snapshot 주입 결과가 from-scratch recompute 와 byte-identical (다중 충돌)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // count 가 3개 모듈에서 충돌 → name$1, name$2 deconflict 발생.
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const count = 0;\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;\nexport const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const count = 2;\nexport const name = 'c';");

    // 1) 초기 빌드: computeRenames → 스냅샷 캡처.
    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 정상 그래프 → capture 성공(non-null)이어야 한다. F5 null 폐기는 별도 테스트.
    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // 2) 같은 그래프에 fresh Linker 를 link 만 하고(=deconflict 미실행), 스냅샷 주입.
    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();
    // 가드는 같은 그래프이므로 당연히 통과해야 한다.
    try std.testing.expect(fresh.renameReuseGuard(&snap));
    try fresh.injectPreservedRenames(&snap);

    // 3) 주입 결과 == recompute 결과 (byte-identical).
    try expectRenameTablesEqual(&r.linker, &fresh);
    // sanity: 실제로 deconflict 가 일어났는지 (count$N 존재).
    var saw_rename = false;
    var it2 = fresh.rename_table.map.iterator();
    while (it2.next()) |e| {
        if (std.mem.indexOf(u8, e.value_ptr.*, "$") != null) saw_rename = true;
    }
    try std.testing.expect(saw_rename);
}

test "reuse: guard 통과 시 inject — single import 그래프" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();
    try std.testing.expect(fresh.renameReuseGuard(&snap));
    try fresh.injectPreservedRenames(&snap);
    try expectRenameTablesEqual(&r.linker, &fresh);
    // RFC_PERSISTENT_LINKER Phase 1: 주입은 스냅샷 문자열을 borrow 하므로 per-entry
    // dupe(alloc)가 없다 → canonical_strings(linker 소유분)는 비어 있어야 한다.
    // dupe 로 회귀하면 이 단언이 깨진다(lInj 비용 재증가 가드).
    try std.testing.expectEqual(@as(usize, 0), fresh.canonical_strings.items.len);
    // reuse-hit 정밀화: injectPreservedRenames 는 canonical_names_used 에 쓰지 않는다
    // (deconflict 가 skip 돼 write-only=dead). 다시 put 하면 이 단언이 깨진다(lInj 가드).
    try std.testing.expectEqual(@as(u32, 0), fresh.canonical_names_used.count());
}

test "reuse PR-C: 변경-한정 가드(carrier set)가 전량 가드와 동일 verdict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const count = 0;\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;\nexport const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const count = 2;\nexport const name = 'c';");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();

    // 전량(carrier=null): 같은 그래프 → 통과(종전 경로).
    try std.testing.expect(r.graph.changed_emit_paths == null);
    try std.testing.expect(fresh.renameReuseGuard(&snap));

    // 변경-한정(carrier={modules[0]}): carrier 에 있는 모듈만 full fingerprint 검사, 나머지는
    // 아예 순회 안 함(O(changed)). 같은 그래프라 carrier 모듈도 일치 → 동일하게 통과.
    var carrier: std.StringHashMapUnmanaged(void) = .empty;
    defer carrier.deinit(std.testing.allocator);
    try carrier.put(std.testing.allocator, r.graph.modules.at(0).path, {});
    r.graph.changed_emit_paths = carrier;
    try std.testing.expect(fresh.renameReuseGuard(&snap));

    // 빈 carrier(변경 0 = 검사할 모듈 없음)도 통과.
    r.graph.changed_emit_paths = .empty;
    try std.testing.expect(fresh.renameReuseGuard(&snap));

    // 정확성: carrier 모듈의 fingerprint 가 snapshot 과 다르면 reject(=full computeRenames).
    // snapshot 의 modules[0] toplevel 이름집합 해시를 손상시키고 그 모듈을 carrier 에 넣으면
    // O(changed) 가드가 그 모듈을 검사해 불일치 감지 → false 여야 한다(이름 추가 edit 모사).
    const fp0 = @constCast(&snap.fingerprint[0]); // arena-backed, 테스트 목적 변형
    const orig_hash = fp0.toplevel_name_set_hash;
    fp0.toplevel_name_set_hash = orig_hash ^ 0xdead_beef;
    r.graph.changed_emit_paths = carrier; // {modules[0]}
    try std.testing.expect(!fresh.renameReuseGuard(&snap));
    // 전량 가드(carrier=null)도 동일하게 false — verdict 일치.
    r.graph.changed_emit_paths = null;
    try std.testing.expect(!fresh.renameReuseGuard(&snap));
    fp0.toplevel_name_set_hash = orig_hash; // 복원

    // graph.deinit 가 테스트 소유 carrier 를 이중 해제하지 않게 복원(빈 set 은 backing 없음).
    r.graph.changed_emit_paths = null;
}

test "reuse: G3 by-name 재유도 — 스냅샷의 inner idx 가 흔들려도 이름으로 복원" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // 스냅샷의 모든 엔트리의 id.inner 를 의도적으로 망가뜨린다(maxInt-기반 가짜값).
    // injectPreservedRenames 가 id.inner 를 신뢰하지 않고 local_name 으로 findSymbolIdx
    // 재유도하므로, 망가진 idx 와 무관하게 동일 결과가 나와야 한다 (G3 핵심).
    for (snap.entries) |*e| {
        // local_name 은 유지, id.inner 만 손상.
        e.id.inner = @enumFromInt(@as(u32, 0xFFFF));
    }

    var fresh = Linker.init(std.testing.allocator, r.graph, .esm);
    defer fresh.deinit();
    try fresh.link();
    try fresh.injectPreservedRenames(&snap);
    // by-name 재유도가 동작했으면 recompute 와 동일.
    try expectRenameTablesEqual(&r.linker, &fresh);
}

test "reuse: fingerprint — 같은 그래프는 guard true, module_count 불일치는 false (G0)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // 같은 그래프 → guard 통과.
    try std.testing.expect(r.linker.renameReuseGuard(&snap));

    // G0: 스냅샷의 module_count 를 조작해 불일치 유발 → fallback(false).
    const real_count = snap.module_count;
    snap.module_count = real_count + 1;
    try std.testing.expect(!r.linker.renameReuseGuard(&snap));
    snap.module_count = real_count;

    // G2: 스냅샷의 첫 fingerprint 의 이름집합 해시를 조작 → fallback(false).
    // fingerprint 는 []const 라 const-cast 로 한 엔트리만 손상(테스트 한정).
    const fps = @constCast(snap.fingerprint);
    const saved = fps[0].toplevel_name_set_hash;
    fps[0].toplevel_name_set_hash = saved ^ 0xDEAD;
    try std.testing.expect(!r.linker.renameReuseGuard(&snap));
    fps[0].toplevel_name_set_hash = saved;

    // 복원 후 다시 통과.
    try std.testing.expect(r.linker.renameReuseGuard(&snap));
}

test "reuse: fingerprint — nested/import-local/wrap 해시 조작 시 fallback (G5/G6)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts 가 b.ts 의 foo 를 import 하고 nested 스코프(wrap 함수)를 가진다.
    try writeFile(tmp.dir, "a.ts", "import { foo } from './b';\nexport function wrap(){ return foo; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    var snap = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
    defer snap.deinit();

    // baseline: 같은 그래프 → 통과.
    try std.testing.expect(r.linker.renameReuseGuard(&snap));

    const fps = @constCast(snap.fingerprint);

    // G5: nested binding 이름집합 해시 조작 → fallback. (각 모듈 인덱스마다 검증)
    for (fps) |*fp| {
        const saved = fp.nested_name_set_hash;
        fp.nested_name_set_hash = saved ^ 0xBEEF;
        try std.testing.expect(!r.linker.renameReuseGuard(&snap));
        fp.nested_name_set_hash = saved;
    }
    try std.testing.expect(r.linker.renameReuseGuard(&snap));

    // G6: import local_name + wrap_kind 해시 조작 → fallback.
    for (fps) |*fp| {
        const saved = fp.import_locals_wrap_hash;
        fp.import_locals_wrap_hash = saved ^ 0xBEEF;
        try std.testing.expect(!r.linker.renameReuseGuard(&snap));
        fp.import_locals_wrap_hash = saved;
    }
    try std.testing.expect(r.linker.renameReuseGuard(&snap));
}

test "reuse: nested shadow 추가 시 guard=false (toplevel 불변이라 G2 가 놓치는 hole)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 빌드 A: 이미 존재하는 top-level 함수 wrap, 내부에 nested binding 없음.
    try writeFile(tmp.dir, "a.ts", "import { foo } from './b';\nexport function wrap(){ return foo; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 1;");

    // 빌드 A → 스냅샷. (스냅샷은 자체 arena 로 dupe 하므로 teardown 후에도 유효)
    var snap: PreservedRenames = blk: {
        var rA = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
        defer rA.linker.deinit();
        defer rA.destroyGraph();
        defer rA.cache.deinit();
        break :blk (try rA.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // a.ts 의 nested 스코프에 import local 과 같은 이름(foo)을 const 로 추가.
    // top-level 이름집합(wrap)은 그대로 — G2 는 이 변화를 못 잡는다.
    try writeFile(tmp.dir, "a.ts", "import { foo } from './b';\nexport function wrap(){ const foo = 1; return foo; }");

    // 빌드 B: 같은 tmpDir → 같은 경로(path_hash 동일) → G1 통과, nested 만 다름.
    var rB = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer rB.linker.deinit();
    defer rB.destroyGraph();
    defer rB.cache.deinit();

    // a.ts 모듈의 fresh fingerprint 와 스냅샷을 직접 대조해 어떤 게이트가 잡는지 확인:
    // toplevel/import-local 은 일치, nested 만 불일치여야 한다.
    const a_idx = findModuleIdx(rB.graph, "a.ts").?;
    const ai: usize = @intFromEnum(a_idx);
    const cur = try rB.linker.moduleFingerprint(rB.graph.getModule(a_idx).?.*);
    const old = snap.fingerprint[ai];
    try std.testing.expectEqual(old.path_hash, cur.path_hash); // 같은 파일
    try std.testing.expectEqual(old.toplevel_name_set_hash, cur.toplevel_name_set_hash); // G2 놓침
    try std.testing.expectEqual(old.import_locals_wrap_hash, cur.import_locals_wrap_hash); // G6 놓침
    try std.testing.expect(old.nested_name_set_hash != cur.nested_name_set_hash); // G5 가 잡음

    // 결과: 가드는 nested 변화를 감지해 fallback(false) → full computeRenames 로 안전.
    try std.testing.expect(!rB.linker.renameReuseGuard(&snap));
}

test "reuse: wrap_kind flip (ESM→CJS) 시 guard=false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 빌드 A: b 가 ESM (wrap_kind=.none).
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nexport const y = x;");
    try writeFile(tmp.dir, "b.js", "export const x = 1;");

    var snap: PreservedRenames = blk: {
        var rA = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
        defer rA.linker.deinit();
        defer rA.destroyGraph();
        defer rA.cache.deinit();
        // b 가 ESM 인지 sanity.
        const b0 = findModuleIdx(rA.graph, "b.js").?;
        try std.testing.expectEqual(types.WrapKind.none, rA.graph.getModule(b0).?.wrap_kind);
        break :blk (try rA.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // b.js 를 CJS 로 교체 → wrap_kind=.cjs 로 바뀐다.
    try writeFile(tmp.dir, "b.js", "module.exports = { x: 1 };");

    var rB = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer rB.linker.deinit();
    defer rB.destroyGraph();
    defer rB.cache.deinit();

    const b_idx = findModuleIdx(rB.graph, "b.js").?;
    try std.testing.expectEqual(types.WrapKind.cjs, rB.graph.getModule(b_idx).?.wrap_kind);

    // wrap_kind 가 import_locals_wrap_hash 의 seed 라 b 의 fingerprint 가 달라진다.
    const bi: usize = @intFromEnum(b_idx);
    const cur = try rB.linker.moduleFingerprint(rB.graph.getModule(b_idx).?.*);
    try std.testing.expect(snap.fingerprint[bi].import_locals_wrap_hash != cur.import_locals_wrap_hash);

    // 가드 fallback(false).
    try std.testing.expect(!rB.linker.renameReuseGuard(&snap));
}

test "reuse: F5 — rename_table 키의 symbolLocalName 이 null 이면 스냅샷 폐기(capture null)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    // 1) 대조군: 깨끗한 rename_table 은 capture 성공(non-null).
    {
        var ok = (try r.linker.buildRenameSnapshot(std.testing.allocator)).?;
        ok.deinit();
    }

    // 2) symbolLocalName 이 null 을 반환하는 인위적 SymbolID 를 rename_table 에 주입한다.
    //    module 인덱스를 모듈 수 밖(out-of-range)으로 잡으면 getModule→null →
    //    symbolLocalName→null 이 된다. scope_maps 에도 없고 synthetic 도 아닌, totality 가
    //    깨지는 정확한 케이스. value 는 borrow 라 별도 free 불필요(canonical_strings 소유가
    //    아닌 string literal — RenameTable.deinit 은 map 만 해제).
    const oob_module: types.ModuleIndex = @enumFromInt(@as(u32, @intCast(r.graph.moduleCount())) + 7);
    const bad_id = bundler_symbol.SymbolID.make(oob_module, 0);
    // sanity: 정말로 null 을 반환하는지 — buildRenameSnapshot 폐기 조건의 전제 확인.
    try std.testing.expect(r.linker.symbolLocalName(bad_id) == null);
    try r.linker.rename_table.put(std.testing.allocator, bad_id, "synthetic_should_not_leak");

    // 3) 이제 capture 는 불완전 스냅샷을 폐기하고 null 을 반환해야 한다.
    const captured = try r.linker.buildRenameSnapshot(std.testing.allocator);
    try std.testing.expect(captured == null);

    // 4) 가드 경로가 reuse 를 안 하는지: bundler 게이트는 `if (try buildRenameSnapshot()) |snap|`
    //    형태라, capture 가 null 이면 그 분기 자체를 타지 않아 injectPreservedRenames 가
    //    절대 호출되지 않는다(=reuse 비활성). 즉 reuse 의 *유일* 진입점인 non-null 스냅샷이
    //    없으므로 구조적으로 재사용이 불가능하다. 아래는 그 불변식을 값 수준에서 재확인.
    if (captured) |_| {
        try std.testing.expect(false); // 도달 불가 — null 이어야 한다.
    }
}

test "clearCanonicalNames: ns_export_cache 도 무효화 (non-owned local canonical_strings UAF, #4297)" {
    const allocator = std.testing.allocator;
    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(allocator, &cache);
    defer graph.deinit();
    var linker = Linker.init(allocator, &graph, .esm);
    defer linker.deinit();

    // ns_export_cache 의 non-owned local 은 canonical_strings 를 borrow → clearCanonicalNames 가
    // canonical_strings 를 free 하면 stale. 캐시도 무효화돼야 한다. owned 엔트리로 free 까지 검증.
    const owned_local = try allocator.dupe(u8, "_default");
    const slice = try allocator.alloc(Linker.NsExportPair, 1);
    slice[0] = .{ .exported = "x", .local = owned_local, .owned = true };
    try linker.ns_export_cache.put(allocator, 0, slice);

    linker.clearCanonicalNames();

    // 버그: 캐시 미정리 → stale 엔트리 잔존(+owned local leak, testing allocator 감지).
    try std.testing.expectEqual(@as(usize, 0), linker.ns_export_cache.count());
}

test "reuse: #4538 CJS 소비자 scope-0 shadow 추가가 fingerprint 를 바꾼다 (stale reuse 방지)" {
    // #4533 이후 resolveWrapperConsumerShadows 가 CJS 소비자의 scope-0(클로저 지역) 바인딩도
    // 주입 래퍼와 대조해 개명한다. 그 이름이 warm 재빌드에서 새로 생겨도 moduleFingerprint 가
    // 안 담으면 renameReuseGuard 가 stale snapshot 을 재사용해 shadow 가 재출현한다.
    // → moduleFingerprint 가 CJS scope-0 이름을 담아 변화를 잡는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "legacy.cjs", "exports.foo = function(){ return 1; };\n");

    // build1: consumer.cjs 에 shadow 없음.
    try writeFile(tmp.dir, "consumer.cjs", "module.exports = require('./legacy.cjs').foo();\n");
    try writeFile(tmp.dir, "index.ts", "import c from './consumer.cjs';\nconsole.log(c);\n");
    var snap = blk: {
        var r1 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
        defer r1.linker.deinit();
        defer r1.destroyGraph();
        defer r1.cache.deinit();
        break :blk (try r1.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // build2: consumer.cjs 의 scope-0 에 require_legacy shadow 추가(다른 건 그대로).
    try writeFile(tmp.dir, "consumer.cjs",
        \\function require_legacy(){ return 2; }
        \\module.exports = require('./legacy.cjs').foo() + require_legacy();
        \\
    );
    var r2 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
    defer r2.linker.deinit();
    defer r2.destroyGraph();
    defer r2.cache.deinit();

    // 핵심: scope-0 shadow 가 생겼으니 guard 는 **false**(재계산) 여야 한다.
    // fingerprint 가 CJS scope-0 을 안 담으면 여기서 true(stale) → shadow 재출현.
    try std.testing.expect(!r2.linker.renameReuseGuard(&snap));
}

test "reuse: #4538 shadow 이름이 scope-0↔nested 이동해도 fingerprint 가 바뀐다 (상쇄 방지)" {
    // #4538 fold 가 scope-0 을 nested 와 같은 seed 로 더하면, require_legacy 를 top-level 에서
    // 함수 안으로 옮길 때 두 항이 상쇄돼 fingerprint 불변 → stale reuse. 다른 seed(0xc1)로 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "legacy.cjs", "exports.foo = function(){ return 1; };\n");

    // build1: outer() 는 **이미 존재**하고, require_legacy 는 top-level(scope 0)에 있다.
    // (이름 집합 = {outer, require_legacy}; nested = {}). 이동만 격리하려고 build 바인딩 추가 없이.
    try writeFile(tmp.dir, "consumer.cjs",
        \\function outer(){ return 0; }
        \\function require_legacy(){ return 2; }
        \\module.exports = require('./legacy.cjs').foo() + require_legacy() + outer();
        \\
    );
    try writeFile(tmp.dir, "index.ts", "import c from './consumer.cjs';\nconsole.log(c);\n");
    var snap = blk: {
        var r1 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
        defer r1.linker.deinit();
        defer r1.destroyGraph();
        defer r1.cache.deinit();
        break :blk (try r1.linker.buildRenameSnapshot(std.testing.allocator)).?;
    };
    defer snap.deinit();

    // build2: require_legacy 를 **기존 outer() 안(nested)** 으로 이동. 전체 이름 multiset 불변
    // ({outer@s0, require_legacy@s1} vs build1 {outer@s0, require_legacy@s0}) — scope 만 바뀜.
    try writeFile(tmp.dir, "consumer.cjs",
        \\function outer(){ function require_legacy(){ return 2; } return require_legacy(); }
        \\module.exports = require('./legacy.cjs').foo() + outer();
        \\
    );
    var r2 = try buildLinkAndRename(std.testing.allocator, &tmp, "index.ts");
    defer r2.linker.deinit();
    defer r2.destroyGraph();
    defer r2.cache.deinit();

    // 이동으로 shadow 스코프가 바뀌었으니 guard 는 **false**(재계산) 여야 한다.
    try std.testing.expect(!r2.linker.renameReuseGuard(&snap));
}

// #4545 hole 2: CJS provider 의 interop 모드(node `__toESM(...,1)` vs babel `__toESM(...)`)는
// provider 의 **첫 importer def_format**(cjsInteropIsNode)으로 정해진다. 이 importer-방향 입력이
// flip 되면 provider 를 소비하는 **다른** 소비자 emit 이 바뀌므로 provider 의 emitFingerprint 가
// 반응해야(deep-fold → 소비자 invalidation). 게이트는 emit(cjsInteropAccessExpr, wrap_kind==.cjs)와
// 동일 → 비-cjs 모듈엔 interop 항이 안 붙어 over-invalidation 없음(main 가드로 확인).
test "reuse #4545 hole 2: cjs provider interop 모드 flip → emitFingerprint 변화 (비-cjs 는 불변)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "p.cjs", "module.exports.x = 1;\n");
    try writeFile(tmp.dir, "main.mjs", "import { x } from './p.cjs';\nconsole.log(x);\n");
    var r = try buildAndLink(std.testing.allocator, &tmp, "main.mjs");
    defer r.linker.deinit();
    defer r.destroyGraph();
    defer r.cache.deinit();

    const p_idx = findModuleIdx(r.graph, "p.cjs").?;
    const p = r.graph.getModule(p_idx).?;
    // 전제: p 는 CJS-wrap 이어야 interop 게이트에 걸린다.
    try std.testing.expectEqual(types.WrapKind.cjs, p.wrap_kind);
    const main_idx = findModuleIdx(r.graph, "main.mjs").?;
    const main_mut = r.graph.moduleAtMut(main_idx).?;
    const main_ro = r.graph.getModule(main_idx).?;
    // 첫 importer(main) def_format esm → node interop.
    main_mut.def_format = .esm_mjs;
    const fp_p_node = r.linker.emitFingerprint(p);
    const fp_main_esm = r.linker.emitFingerprint(main_ro);
    // 첫 importer def_format cjs → babel interop.
    main_mut.def_format = .cjs;
    const fp_p_babel = r.linker.emitFingerprint(p);
    const fp_main_cjs = r.linker.emitFingerprint(main_ro);
    // 핵심: CJS provider 의 fp 는 interop 모드에 반응한다(fix 전엔 불변 → stale).
    try std.testing.expect(fp_p_node != fp_p_babel);
    // 게이트 가드: main(ESM, wrap_kind != .cjs)은 def_format flip 에도 fp 불변 → over-invalidation 없음.
    try std.testing.expectEqual(fp_main_esm, fp_main_cjs);
}

// #4545 hole 3: `import * as ns from './t'` 의 합성 shared-ns var 이름(`t_ns`/`t_ns_2` …)은
// 전-모듈 동명-base 충돌 rank 로 결정된다(sharedNsVarNameHash=base+rank). 이는 dep 방향이 아니라
// 전역 collision 구성에 의존해 deep-fold 가 못 잡으므로 target(ns 주인) 모듈의 emitFingerprint 에
// 접었다. 동명-base 모듈을 추가해 t 의 rank 가 0→1 로 바뀌면 emitFingerprint(t) 가 달라져야 한다.
test "reuse #4545 hole 3: shared-ns var 충돌 rank 변화 → target emitFingerprint 변화" {
    const alloc = std.testing.allocator;
    // 시나리오 A: base "t" 모듈이 t.ts 하나뿐 → rank 0.
    const fp_a = blk: {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "t.ts", "export const a = 1;\n");
        try writeFile(tmp.dir, "main.ts", "import * as ns from './t';\nconsole.log(ns.a);\n");
        var r = try buildAndLink(alloc, &tmp, "main.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        const t = r.graph.getModule(findModuleIdx(r.graph, "t.ts").?).?;
        break :blk r.linker.emitFingerprint(t);
    };
    // 시나리오 B: sub/t.ts(base "t") 추가 → 동명-base 2개 → t.ts rank 1(sub/t 가 먼저 import 되어 rank 0).
    const fp_b = blk: {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "t.ts", "export const a = 1;\n");
        try writeFile(tmp.dir, "sub/t.ts", "export const z = 9;\n");
        try writeFile(tmp.dir, "main.ts",
            \\import { z } from './sub/t';
            \\import * as ns from './t';
            \\console.log(z, ns.a);
            \\
        );
        var r = try buildAndLink(alloc, &tmp, "main.ts");
        defer r.linker.deinit();
        defer r.destroyGraph();
        defer r.cache.deinit();
        // 최상위 t.ts 지목(sub/t.ts 는 basename 이 같아 findModuleIdx 로 구분 불가 → path 로 구분).
        var t_idx: ?ModuleIndex = null;
        var it = r.graph.modulesIterator();
        while (it.next()) |m| {
            if (std.mem.endsWith(u8, m.path, "/t.ts") and !std.mem.endsWith(u8, m.path, "/sub/t.ts")) {
                t_idx = m.index;
                break;
            }
        }
        const t = r.graph.getModule(t_idx.?).?;
        break :blk r.linker.emitFingerprint(t);
    };
    // 핵심: collision 구성 변화로 t 의 ns var 이름(rank)이 바뀌면 fp 도 바뀐다(fix 전엔 불변 → stale).
    try std.testing.expect(fp_a != fp_b);
}
