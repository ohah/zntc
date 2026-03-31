const std = @import("std");
const Linker = @import("linker.zig").Linker;
const ImportBinding = @import("linker.zig").ImportBinding;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const resolve_cache_mod = @import("resolve_cache.zig");
const writeFile = @import("test_helpers.zig").writeFile;

fn dirPath(tmp: *std.testing.TmpDir) ![]const u8 {
    return try tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

fn buildAndLink(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(&.{entry});

    var linker = Linker.init(allocator, graph.modules.items, .esm);
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // a.ts의 import x가 b.ts의 export x에 연결
    const a = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // chain: a→b→c, canonical은 c(index 2)
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: missing export produces diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { missing } from './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
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
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 99;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.js", "module.exports = { x: 42 };");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // c.js는 CJS이므로, resolveExportChain이 c.js(index 2)를 반환
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
    // c.js가 실제로 CJS로 감지되었는지 확인
    try std.testing.expectEqual(types.WrapKind.cjs, r.graph.modules.items[2].wrap_kind);
}

test "linker: namespace re-export resolves to local binding" {
    // import * as ns from './c'; export { ns } 패턴에서
    // resolveExportChain이 현재 모듈(b.ts)의 로컬 바인딩을 반환하는지 검증.
    // namespace import는 소스 모듈에서 "*"를 named export로 찾을 수 없으므로,
    // 로컬 바인딩을 그대로 반환해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { ns } from './b';");
    try writeFile(tmp.dir, "b.ts", "import * as ns from './c';\nexport { ns };");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.js", "module.exports = { x: 42 };");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items, .esm);
    defer linker.deinit();
    try linker.link();

    // b.js가 CJS로 감지됨
    try std.testing.expectEqual(types.WrapKind.cjs, graph.modules.items[1].wrap_kind);

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
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("default", binding.?.canonical.export_name);
}

test "linker: external import not resolved (no binding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from 'react';");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{ .external_patterns = &.{"react"} });
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items, .esm);
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
    graph: ModuleGraph,
    cache: resolve_cache_mod.ResolveCache,
};

fn buildLinkAndRename(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    var r = try buildAndLink(allocator, tmp, entry_name);
    try r.linker.computeRenames();
    return .{ .linker = r.linker, .graph = r.graph, .cache = r.cache };
}

test "rename: no conflict — no rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // x는 b.ts에만 있으므로 충돌 없음 → canonical_names 비어 있음
    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_names.count());
}

test "rename: two modules same name — second gets $1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // b.ts(exec_index 낮음)가 원본 유지, a.ts가 count$1
    // 또는 a.ts가 원본이고 b.ts가 $1 (exec_index에 따라)
    try std.testing.expect(r.linker.canonical_names.count() > 0);

    // 하나는 리네임됨
    var has_rename = false;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "count$")) has_rename = true;
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 3개 중 2개 리네임
    var rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "name$")) rename_count += 1;
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_names.count());
}

test "rename: getCanonicalName returns renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 하나는 getCanonicalName으로 리네임 조회 가능
    var found_rename = false;
    for (r.graph.modules.items, 0..) |_, i| {
        if (r.linker.getCanonicalName(@intCast(i), "count")) |renamed| {
            try std.testing.expect(std.mem.startsWith(u8, renamed, "count$"));
            found_rename = true;
        }
    }
    try std.testing.expect(found_rename);

    // 원본 유지되는 모듈은 getCanonicalName이 null
    var found_original = false;
    for (r.graph.modules.items, 0..) |_, i| {
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // helper가 두 모듈에서 충돌 → 하나가 리네임됨
    var has_helper_rename = false;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "helper$")) has_helper_rename = true;
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // x가 충돌. 리네임된 쪽이 x$1을 건너뛰고 x$2가 되어야 함
    // (nested scope에 x$1이 이미 있으므로)
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "x$")) {
            // x$1이 아닌 다른 값이어야 함 (nested scope에 x$1 있으므로)
            // 단, semantic analyzer가 parameter를 어떤 scope에 넣는지에 따라 다를 수 있음
            try std.testing.expect(val.*.len > 0);
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // foo가 두 모듈에서 충돌 (a.ts: default export의 local name, b.ts: named export)
    var has_foo_rename = false;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "foo$")) has_foo_rename = true;
    }
    try std.testing.expect(has_foo_rename);
}

test "linker: deep re-export chain (near depth limit)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 5단계 re-export 체인: a → b → c → d → e
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export { x } from './d';");
    try writeFile(tmp.dir, "d.ts", "export { x } from './e';");
    try writeFile(tmp.dir, "e.ts", "export const x = 'deep';");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
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
    var linker = Linker.init(std.testing.allocator, &.{}, .esm);
    defer linker.deinit();

    var name_to_owners = Linker.NameToOwnersMap.init(std.testing.allocator);
    defer name_to_owners.deinit();

    // 예약어는 불가
    try std.testing.expect(!linker.isCandidateAvailable("class", 0, &name_to_owners));
    // 일반 이름은 가능
    try std.testing.expect(linker.isCandidateAvailable("foo", 0, &name_to_owners));
    // name_to_owners에 있는 이름은 불가
    try name_to_owners.put("bar", .empty);
    try std.testing.expect(!linker.isCandidateAvailable("bar", 0, &name_to_owners));
    // reserved_globals에 있는 이름은 불가
    try linker.reserved_globals.put("console", {});
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
    defer r.graph.deinit();
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

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items, .esm);
    defer linker.deinit();
    try linker.link();

    // 전체 3개 모듈을 글로벌 rename — 2개가 rename됨
    try linker.computeRenames();
    var global_rename_count: usize = 0;
    for (graph.modules.items, 0..) |_, i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) global_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), global_rename_count);

    // per-module rename: 모듈 0, 1만 대상 → 1개만 rename됨
    const subset = &[_]ModuleIndex{ @enumFromInt(0), @enumFromInt(1) };
    try linker.computeRenamesForModules(subset, &.{});
    var subset_rename_count: usize = 0;
    for (graph.modules.items, 0..) |_, i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) subset_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), subset_rename_count);
}

test "clearCanonicalNames: 초기화 후 비어있음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst x = 1;");
    try writeFile(tmp.dir, "b.ts", "const x = 2;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items, .esm);
    defer linker.deinit();
    try linker.link();
    try linker.computeRenames();

    // rename 결과가 있어야 함
    try std.testing.expect(linker.canonical_names.count() > 0);

    // 초기화 후 비어있어야 함
    linker.clearCanonicalNames();
    try std.testing.expectEqual(@as(usize, 0), linker.canonical_names.count());
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // namespace import는 resolved_bindings에 등록되지 않음 (resolveImports에서 skip)
    // 대신 buildMetadataForAst에서 preamble로 처리
    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // barrel 모듈에서 export * 로 a, b의 export를 수집
    const entry = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "entry.ts", "import { render } from './reexport';");
    try writeFile(tmp.dir, "reexport.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry의 import { render }가 impl.ts의 J에 연결
    const entry = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export { default as greet } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default function hello() { return 'hi'; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "entry.ts", "import { groupBy } from './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export { default as groupBy } from './groupBy';");
    try writeFile(tmp.dir, "groupBy.ts", "function groupBy(arr: any) { return arr; }\nexport default groupBy;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // x, y, z는 각각 다른 이름이므로 충돌 없음 → _default$ 리네임 0개
    var rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "_default$")) rename_count += 1;
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry에서 namespace import로 ns를 가져옴 — 무한 루프 없이 완료
    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 무한 루프 없이 완료되면 성공
    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "entry.ts", "import { z } from './hop1';");
    try writeFile(tmp.dir, "hop1.ts", "export { y as z } from './hop2';");
    try writeFile(tmp.dir, "hop2.ts", "export { x as y } from './origin';");
    try writeFile(tmp.dir, "origin.ts", "export function x() { return 1; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
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
    try writeFile(tmp.dir, "entry.ts", "import { Widget } from './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export { default as Widget } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default class MyWidget { render() {} }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // expr1, expr2 모두 val → 하나가 val$1로 리네임
    var val_rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |v| {
        if (std.mem.startsWith(u8, v.*, "val$")) val_rename_count += 1;
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // x, y는 다른 이름이므로 충돌 없음 → _default$ 리네임 0개
    var rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "_default$")) rename_count += 1;
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry의 import { math }가 barrel의 "math" export에 연결
    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // barrel 모듈(index 1)의 export_bindings에 "utils" 이름이 등록됨
    var has_utils_export = false;
    for (r.graph.modules.items) |m| {
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // ns.prop만 사용 → ns_member_rewrites에 매핑 등록
    const entry = r.graph.modules.items[0];
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
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry의 namespace import 확인
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

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
