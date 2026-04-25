const std = @import("std");
const emitter = @import("emitter.zig");
const emit = emitter.emit;
const EmitOptions = emitter.EmitOptions;
const appendRuntimeHelpers = emitter.appendRuntimeHelpers;
const RuntimeHelpers = @import("../transformer/transformer.zig").RuntimeHelpers;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const chunk_mod = @import("chunk.zig");
const resolve_cache_mod = @import("resolve_cache.zig");
const writeFile = @import("test_helpers.zig").writeFile;

fn buildGraph(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !struct { graph: ModuleGraph, cache: resolve_cache_mod.ResolveCache } {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(&.{entry});
    return .{ .graph = graph, .cache = cache };
}

test "emitter: single module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // TS 타입 스트리핑: "const x: number = 1;" → "const x = 1;"
    try std.testing.expect(std.mem.indexOf(u8, output, "const x = 1;") != null);
}

test "emitter: two modules exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 1;");
    try writeFile(tmp.dir, "b.ts", "const b = 2;");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // b.ts가 a.ts보다 먼저 출력 (exec_index 순서)
    const b_pos = std.mem.indexOf(u8, output, "const b = 2;") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, output, "const a = 1;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b_pos < a_pos);
}

test "emitter: minified output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{ .minify_whitespace = true }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // minify: 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, output, "// ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x=1;") != null);
}

test "emitter: IIFE format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{ .format = .iife }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    try std.testing.expect(std.mem.startsWith(u8, output, "(() => {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n"));
}

test "emitter: IIFE format — ES5 target uses `function` wrapper" {
    // arrow 미지원 타겟(ES5)에서는 기존 `(function() { ... })()` 형태를 유지해야 한다.
    const compat = @import("../transformer/compat.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "var x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .unsupported = compat.fromESTarget(.es5),
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    try std.testing.expect(std.mem.startsWith(u8, output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n"));
}

test "emitter: CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{ .format = .cjs }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    try std.testing.expect(std.mem.startsWith(u8, output, "\"use strict\";\n"));
}

test "emitter: empty graph" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    const emit_result = try emit(std.testing.allocator, &graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "emitter: chain A → B → C order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 'a';");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconst b = 'b';");
    try writeFile(tmp.dir, "c.ts", "const c = 'c';");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // C → B → A 순서
    const c_pos = std.mem.indexOf(u8, output, "const c = \"c\";") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, output, "const b = \"b\";") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, output, "const a = \"a\";") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c_pos < b_pos);
    try std.testing.expect(b_pos < a_pos);
}

test "emitter: TS enum and interface stripping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\interface Foo { x: number; }
        \\enum Color { Red, Green, Blue }
        \\const x: Foo = { x: 1 };
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // interface 제거됨
    try std.testing.expect(std.mem.indexOf(u8, output, "interface") == null);
    // enum → IIFE 변환
    try std.testing.expect(std.mem.indexOf(u8, output, "Color") != null);
    // 일반 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, output, "const x") != null);
}

// ============================================================
// Single-use Inline Bundle Tests (#1666 Phase 2+3)
// ============================================================

test "inline (bundle): 함수 body 안 literal — inline" {
    // single-file 테스트는 minify_test.zig 가 커버. 이 테스트는 bundler 경로 (emit)
    // 에서도 inline 이 동작함을 확인 — emitter 가 initInPlace 를 통해 module.ast 를
    // mutate 하고 minify 의 inline pass 가 그 위에서 도는 흐름을 end-to-end 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\function work() {
        \\  const n = 42;
        \\  return n;
        \\}
        \\console.log(work());
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // work 내부 const n=42 는 return 에 inline 되어 사라졌어야.
    try std.testing.expect(std.mem.indexOf(u8, output, "const n = 42") == null);
    // return 42 가 출력에 존재 (inline 결과).
    try std.testing.expect(std.mem.indexOf(u8, output, "return 42") != null);
}

test "inline (bundle): top-level const — 보존 (scope=0)" {
    // module top-level 은 tree-shaker 영역이라 inline 하지 않는다 (scope_id=0 가드).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\const MODE = "production";
        \\console.log(MODE);
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // 여전히 MODE 선언이 남아있고 console.log 가 그걸 참조.
    try std.testing.expect(std.mem.indexOf(u8, output, "MODE") != null);
}

test "inline (bundle): 크로스 모듈 — 각 모듈 함수 내부 별개로 inline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "helpers.ts",
        \\export function dbl(x: number) {
        \\  const factor = 2;
        \\  return x * factor;
        \\}
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { dbl } from "./helpers";
        \\function run() {
        \\  const base = 10;
        \\  return dbl(base);
        \\}
        \\console.log(run());
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // 두 함수의 internal const 모두 inline.
    try std.testing.expect(std.mem.indexOf(u8, output, "const factor") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const base") == null);
    // inline 결과물 확인.
    try std.testing.expect(std.mem.indexOf(u8, output, "x * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dbl(10)") != null);
}

test "inline (bundle): container literal 여러 모듈에 걸쳐" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "config.ts",
        \\export function defaults() {
        \\  const cfg = { timeout: 5000, retries: 3 };
        \\  return cfg;
        \\}
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { defaults } from "./config";
        \\function load() {
        \\  const opts = [1, 2, 3];
        \\  return { opts, ...defaults() };
        \\}
        \\console.log(load());
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // cfg 는 inline 되어 사라짐.
    try std.testing.expect(std.mem.indexOf(u8, output, "const cfg") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return { timeout: 5000, retries: 3 }") != null);
    // opts 는 shorthand property 의 value 가 identifier_reference 라 inline 조건 미충족 → 보존.
    try std.testing.expect(std.mem.indexOf(u8, output, "const opts") != null);
}

test "inline (bundle): minify_syntax 플래그 없어도 inline 실행 (#1552)" {
    // #1552 per: minify pass 는 --minify 여부와 무관하게 항상 실행 — inline 도 따라간다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\function compute() {
        \\  const answer = 42;
        \\  return answer;
        \\}
        \\compute();
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    // minify_syntax=false (기본) — 그래도 inline 돌아야 함.
    const emit_result = try emit(std.testing.allocator, &result.graph, .{ .minify_syntax = false }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    try std.testing.expect(std.mem.indexOf(u8, output, "const answer") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "return 42") != null);
}

test "inline (bundle): shared module 내부 inline — emitChunks 경로" {
    // code splitting 으로 shared module 이 common chunk 에 올라가는 시나리오.
    // emitChunks 도 D1c 이후 in-place 경로라 inline 동작해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shared.ts",
        \\export function helper() {
        \\  const secret = "x";
        \\  return secret;
        \\}
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { helper } from "./shared";
        \\console.log("a:", helper());
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { helper } from "./shared";
        \\console.log("b:", helper());
    );

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // common chunk 에서 helper 의 const secret 이 inline 되었는지 확인.
    var found_inlined = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "const secret") != null) return error.TestUnexpectedResult;
        if (std.mem.indexOf(u8, o.contents, "return \"x\"") != null) {
            found_inlined = true;
        }
    }
    try std.testing.expect(found_inlined);
}

// ============================================================
// emitChunks Tests
// ============================================================

fn buildGraphMultiEntry(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_names: []const []const u8) !struct { graph: ModuleGraph, cache: resolve_cache_mod.ResolveCache } {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }
    for (entry_names) |name| {
        try entries.append(allocator, try std.fs.path.resolve(allocator, &.{ dp, name }));
    }

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(entries.items);
    return .{ .graph = graph, .cache = cache };
}

test "emitChunks: single chunk produces one OutputFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{entry_path}, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqualStrings("index.js", outputs[0].path);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].contents, "const x = 1;") != null);
}

test "emitChunks: two entries with shared module — 3 OutputFiles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "console.log('shared');");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, &result.graph, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // 2 엔트리 + 1 공통 = 3 파일
    try std.testing.expectEqual(@as(usize, 3), outputs.len);

    // shared 코드는 정확히 1개의 출력에만 포함
    var shared_count: usize = 0;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "\"shared\"") != null) shared_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared_count);
}

// ============================================================
// rewriteDynamicImports Tests
// ============================================================

test "CodeSplitting: dynamic import path rewritten to chunk filename" {
    // 설정: index.ts가 import('./lazy')로 lazy.ts를 동적 import.
    // lazy.ts가 별도 청크에 속할 때, import('./lazy') → import('./lazy.js')로 리라이트 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const load = () => import('./lazy');");
    try writeFile(tmp.dir, "lazy.ts", "export const x = 42;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    // lazy.ts를 별도 엔트리로도 추가하여 별도 청크가 생성되도록 함
    const lazy_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "lazy.ts" });
    defer std.testing.allocator.free(lazy_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ entry_path, lazy_path }, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // index.js 출력에서 import 경로가 리라이트되었는지 확인
    var found_rewrite = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.path, "index") != null) {
            // 리라이트 후: import('./lazy.js') 또는 import("./lazy.js")
            if (std.mem.indexOf(u8, o.contents, "./lazy.js") != null) {
                found_rewrite = true;
            }
            // 원본 specifier('./lazy')가 그대로 남아있으면 안 됨
            // (단, './lazy.js'에 './lazy'가 부분 매칭되므로 정확히 확인)
            if (std.mem.indexOf(u8, o.contents, "'./lazy'") != null or
                std.mem.indexOf(u8, o.contents, "\"./lazy\"") != null)
            {
                // 원본이 리라이트 없이 남아있음 — 실패
                try std.testing.expect(false);
            }
            break;
        }
    }
    try std.testing.expect(found_rewrite);
}

test "CodeSplitting: multiple dynamic imports rewritten" {
    // 설정: index.ts가 두 개의 동적 import를 가짐.
    // 둘 다 별도 청크에 속할 때, 양쪽 모두 리라이트 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\const a = () => import('./pageA');
        \\const b = () => import('./pageB');
    );
    try writeFile(tmp.dir, "pageA.ts", "export const a = 1;");
    try writeFile(tmp.dir, "pageB.ts", "export const b = 2;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);
    const pageA_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "pageA.ts" });
    defer std.testing.allocator.free(pageA_path);
    const pageB_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "pageB.ts" });
    defer std.testing.allocator.free(pageB_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ entry_path, pageA_path, pageB_path }, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // index.js에서 두 경로 모두 리라이트 확인
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.path, "index") != null) {
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "./pageA.js") != null);
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "./pageB.js") != null);
            break;
        }
    }
}

// ============================================================
// Content Hash Filename Tests
// ============================================================

test "chunkStem: common chunk uses hex hash, not index" {
    // 공통 청크의 파일명이 chunk-{hex} 형식인지 확인.
    // 같은 모듈 조합이면 항상 같은 해시가 나와야 한다 (결정론적).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, &result.graph, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // 공통 청크 파일명이 chunk-{8자리 hex}.js 형식인지 확인
    var found_hash_chunk = false;
    for (outputs) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) {
            found_hash_chunk = true;
            // "chunk-" 뒤에 8자리 hex + ".js"여야 함
            const after_prefix = o.path["chunk-".len..];
            try std.testing.expect(after_prefix.len == 8 + ".js".len); // "XXXXXXXX.js"
            // hex 문자만 포함되는지 확인
            for (after_prefix[0..8]) |c| {
                try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
            }
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
        }
    }
    try std.testing.expect(found_hash_chunk);
}

test "chunkStem: same modules produce same hash (deterministic)" {
    // 같은 모듈 조합으로 두 번 빌드해도 같은 chunk 파일명이 나와야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    var result1 = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result1.graph.deinit();
    defer result1.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg1 = try chunk_mod.generateChunks(std.testing.allocator, &result1.graph, &.{ ep_a, ep_b }, .{});
    defer cg1.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg1, &result1.graph, std.testing.allocator, null);

    const outputs1 = try emitter.emitChunks(std.testing.allocator, &result1.graph, &cg1, .{}, null);
    defer {
        for (outputs1) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs1);
    }

    // 두 번째 빌드
    var result2 = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result2.graph.deinit();
    defer result2.cache.deinit();

    var cg2 = try chunk_mod.generateChunks(std.testing.allocator, &result2.graph, &.{ ep_a, ep_b }, .{});
    defer cg2.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg2, &result2.graph, std.testing.allocator, null);

    const outputs2 = try emitter.emitChunks(std.testing.allocator, &result2.graph, &cg2, .{}, null);
    defer {
        for (outputs2) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs2);
    }

    // 공통 청크 파일명이 동일한지 확인
    var chunk_name1: ?[]const u8 = null;
    var chunk_name2: ?[]const u8 = null;
    for (outputs1) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) chunk_name1 = o.path;
    }
    for (outputs2) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) chunk_name2 = o.path;
    }
    try std.testing.expect(chunk_name1 != null);
    try std.testing.expect(chunk_name2 != null);
    try std.testing.expectEqualStrings(chunk_name1.?, chunk_name2.?);
}

// ============================================================
// Content Hash Tests
// ============================================================

test "content hash: same content produces same hash" {
    // 동일한 코드 내용이면 동일한 content hash가 나와야 한다.
    const content = "const x = 1;\nexport { x };";
    var hash1: [8]u8 = undefined;
    var hash2: [8]u8 = undefined;
    emitter.contentHash(content, &hash1);
    emitter.contentHash(content, &hash2);
    try std.testing.expectEqualStrings(&hash1, &hash2);
}

test "content hash: different content produces different hash" {
    // 다른 코드 내용이면 다른 content hash가 나와야 한다.
    var hash1: [8]u8 = undefined;
    var hash2: [8]u8 = undefined;
    emitter.contentHash("const x = 1;", &hash1);
    emitter.contentHash("const x = 2;", &hash2);
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "content hash: ignores placeholders in content" {
    // content에 placeholder가 포함되어 있어도 placeholder를 제외하고 해시해야 한다.
    // 이는 자기 참조 순환을 방지하기 위함.
    const prefix = "\x00ZH";
    const placeholder = prefix ++ "abcdef01";
    const content1 = "import '" ++ placeholder ++ "'; const x = 1;";
    const content2 = "import '" ++ prefix ++ "12345678" ++ "'; const x = 1;";
    var hash1: [8]u8 = undefined;
    var hash2: [8]u8 = undefined;
    emitter.contentHash(content1, &hash1);
    emitter.contentHash(content2, &hash2);
    // placeholder 부분이 달라도, 나머지가 같으면 같은 해시
    try std.testing.expectEqualStrings(&hash1, &hash2);
}

test "naming pattern: [name] only" {
    var buf: [128]u8 = undefined;
    const result = emitter.applyNamingPattern(&buf, "[name]", "index", "abcdef01");
    try std.testing.expectEqualStrings("index", result);
}

test "naming pattern: [name]-[hash]" {
    var buf: [128]u8 = undefined;
    const result = emitter.applyNamingPattern(&buf, "[name]-[hash]", "chunk", "abcdef01");
    try std.testing.expectEqualStrings("chunk-abcdef01", result);
}

test "naming pattern: directory prefix" {
    var buf: [128]u8 = undefined;
    const result = emitter.applyNamingPattern(&buf, "chunks/[name]-[hash]", "chunk", "12345678");
    try std.testing.expectEqualStrings("chunks/chunk-12345678", result);
}

test "naming pattern: no placeholders" {
    var buf: [128]u8 = undefined;
    const result = emitter.applyNamingPattern(&buf, "bundle", "index", "abcdef01");
    try std.testing.expectEqualStrings("bundle", result);
}

test "naming pattern: entry-names with hash" {
    // --entry-names=[name]-[hash] 설정 시 엔트리 청크에도 hash가 붙는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{entry_path}, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{
        .entry_names = "[name]-[hash]",
    }, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    // 파일명이 "index-{8hex}.js" 형식인지 확인
    try std.testing.expect(std.mem.startsWith(u8, outputs[0].path, "index-"));
    try std.testing.expect(std.mem.endsWith(u8, outputs[0].path, ".js"));
    // "index-" (6) + 8hex + ".js" (3) = 17
    try std.testing.expectEqual(@as(usize, 17), outputs[0].path.len);
}

test "naming pattern: chunk-names with directory" {
    // --chunk-names=chunks/[name]-[hash] 설정 시 공통 청크 경로에 디렉토리가 포함되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, &result.graph, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{
        .chunk_names = "chunks/[name]-[hash]",
    }, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // 공통 청크가 "chunks/" 디렉토리 prefix를 가지는지 확인
    var found_chunk = false;
    for (outputs) |o| {
        if (std.mem.startsWith(u8, o.path, "chunks/")) {
            found_chunk = true;
            try std.testing.expect(std.mem.startsWith(u8, o.path, "chunks/chunk-"));
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
        }
    }
    try std.testing.expect(found_chunk);
}

test "content hash: cross-chunk import uses content hash" {
    // cross-chunk import 경로에도 content hash가 적용되는지 확인.
    // 엔트리 청크가 공통 청크를 import할 때, 경로에 content hash가 포함되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { shared } from './shared';\nconsole.log('a', shared);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './shared';\nconsole.log('b', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, &result.graph, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // 공통 청크의 파일명 찾기
    var chunk_filename: ?[]const u8 = null;
    for (outputs) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) {
            chunk_filename = o.path;
        }
    }
    try std.testing.expect(chunk_filename != null);

    // 공통 청크의 stem (확장자 제외)
    const chunk_stem = chunk_filename.?[0 .. chunk_filename.?.len - ".js".len];

    // 엔트리 청크의 import 문에 공통 청크 stem이 포함되어야 한다
    var found_import = false;
    for (outputs) |o| {
        if (!std.mem.startsWith(u8, o.path, "chunk-")) {
            if (std.mem.indexOf(u8, o.contents, chunk_stem) != null) {
                found_import = true;
            }
        }
    }
    try std.testing.expect(found_import);

    // placeholder ("\x00ZH") 문자가 최종 출력에 남아있으면 안 된다
    for (outputs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\x00ZH") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.path, "\x00ZH") == null);
    }
}

// ============================================================
// CJS Runtime Deduplication Tests
// ============================================================

test "CJS runtime: __commonJS only in chunks containing CJS modules" {
    // CJS 모듈이 없는 청크에는 __commonJS 런타임이 주입되지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts는 ESM만 사용 — CJS 런타임 불필요
    try writeFile(tmp.dir, "a.ts", "export const a = 1;");
    // b.ts도 ESM만 사용
    try writeFile(tmp.dir, "b.ts", "export const b = 2;");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{ ep_a, ep_b }, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // 어떤 청크에도 __commonJS가 없어야 함 (순수 ESM이므로)
    for (outputs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "__commonJS") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "__toESM") == null);
    }
}

test "CodeSplitting: static import not rewritten" {
    // 설정: index.ts가 static import만 사용 — 경로 리라이트 없어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, &result.graph, &.{entry_path}, .{});
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, &result.graph, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            o.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(outputs);
    }

    // 단일 청크 — static import는 linker가 제거하므로 경로가 출력에 없음
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    // import('./lib.js') 같은 동적 import 경로가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].contents, "import('./") == null);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].contents, "import(\"./") == null);
}

// ================================================================
// 런타임 헬퍼 주입 유닛 테스트
// ================================================================

test "appendRuntimeHelpers: no helpers → empty" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{}, false, false);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendRuntimeHelpers: extends only" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .extends = true }, false, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "__generator") == null);
}

test "appendRuntimeHelpers: generator only" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .generator = true }, false, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "__extends") == null);
}

test "appendRuntimeHelpers: rest only" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .rest = true }, false, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __rest") != null);
}

test "appendRuntimeHelpers: multiple helpers" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .extends = true, .generator = true, .rest = true }, false, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __rest") != null);
}

test "appendRuntimeHelpers: minified" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .generator = true }, true, false);
    // #1621: minify 시 __generator → $gn 축약.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var $gn=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __generator") == null);
    // minified에는 줄바꿈이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\n") == null);
}

test "appendRuntimeHelpers: generator runtime is valid JS" {
    // __generator가 올바른 JS인지 기본 구조 검증
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .generator = true }, false, false);
    // 핵심 구조 요소 존재 확인
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "label: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Symbol.iterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "function verb") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "function step") != null);
}

// #1755: GENERATOR_RUNTIME_MIN 에 닫는 brace `}` 가 하나 누락되어 RN+minify 번들이
// SyntaxError: Unexpected end of input 으로 파싱 실패. 문자열 외부의 brace 균형 검증.
test "GENERATOR_RUNTIME_MIN: brace balance" {
    const rt = @import("runtime_helpers.zig");
    const src = rt.GENERATOR_RUNTIME_MIN;
    var opens: u32 = 0;
    var closes: u32 = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        // 문자열 literal 스킵 (escape 처리)
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\') {
                    i += 1; // 다음 루프 iteration 의 i+=1 이 escape 된 char 를 지나감
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        if (c == '{') opens += 1;
        if (c == '}') closes += 1;
    }
    try std.testing.expectEqual(opens, closes);
}

// ============================================================
// banner/footer Tests
// ============================================================

test "banner/footer — basic ESM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .banner_js = "/* banner */",
        .footer_js = "/* footer */",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // banner가 맨 앞에 위치
    try std.testing.expect(std.mem.startsWith(u8, output, "/* banner */\n"));
    // footer가 맨 뒤에 위치
    try std.testing.expect(std.mem.endsWith(u8, output, "/* footer */\n"));
}

test "banner/footer — IIFE format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .banner_js = "// license header",
        .footer_js = "// end",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // banner → IIFE prologue → code → IIFE epilogue → footer
    try std.testing.expect(std.mem.startsWith(u8, output, "// license header\n(() => {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n// end\n"));
}

test "banner/footer — CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .cjs,
        .banner_js = "/* CJS banner */",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // banner가 "use strict" 앞에 위치
    try std.testing.expect(std.mem.startsWith(u8, output, "/* CJS banner */\n\"use strict\";\n"));
}

// ============================================================
// globalName Tests
// ============================================================

test "IIFE + globals: epilogue emits factory call args (#1824)" {
    // external 이 없는 그래프라도 `options.globals` 가 설정되어 있으면 external
    // 수집이 활성화되지만 ext_specifiers 가 비어있으면 기존 `})();\n` 경로.
    // 이 테스트는 "globals 옵션이 비어있을 때는 기존 epilogue 유지" 를 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    // globals 비어있음 → 기존 IIFE 경로
    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .globals = &.{},
    }, null);
    defer emit_result.deinit(std.testing.allocator);

    // 정적 factory_fn ("(() => {\n") + 빈 factory call ("})();\n")
    try std.testing.expect(std.mem.startsWith(u8, emit_result.output, "(() => {\n"));
    try std.testing.expect(std.mem.endsWith(u8, emit_result.output, "})();\n"));
}

test "globalName — IIFE wrapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .global_name = "MyLib",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // prologue: "var MyLib = (() => {\n"
    try std.testing.expect(std.mem.startsWith(u8, output, "var MyLib = (() => {\n"));
    // epilogue: "})();\n"
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n"));
}

test "globalName — dotted name warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .global_name = "MyApp.Utils",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // 경고 주석이 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, output, "[ZTS WARNING] Dotted globalName") != null);
    // dotted name이면 일반 IIFE로 폴백
    try std.testing.expect(std.mem.indexOf(u8, output, "(() => {\n") != null);
}

test "globalName — ignored for non-IIFE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .esm,
        .global_name = "MyLib",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // ESM에서는 globalName이 무시됨
    try std.testing.expect(std.mem.indexOf(u8, output, "var MyLib") == null);
}

test "globalName — with banner/footer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .global_name = "MyLib",
        .banner_js = "/* license */",
        .footer_js = "/* end */",
    }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // banner → globalName prologue → code → epilogue → footer
    try std.testing.expect(std.mem.startsWith(u8, output, "/* license */\nvar MyLib = (() => {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n/* end */\n"));
}

// ============================================================
// JSON Module Tests
// ============================================================

test "JSON module — ESM format" {
    // JSON → ESM AST: export default {...} → 번들 모드에서 var _default = {...}
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value","num":42}
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{ .format = .esm }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // JSON ESM: object 내용이 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, output, "\"key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"value\"") != null);
    // __commonJS 래핑 없음
    try std.testing.expect(std.mem.indexOf(u8, output, "__commonJS") == null);
}

test "JSON module — CJS format" {
    // CJS 포맷에서도 JSON ESM AST는 정상 출력됨.
    // JSON 모듈은 wrap_kind=.none이므로 ESM codegen → var 할당 형태.
    // CJS 래핑은 require()로 참조될 때만 graph가 wrap_kind를 변경.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value"}
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const emit_result = try emit(std.testing.allocator, &result.graph, .{ .format = .cjs }, null);
    defer emit_result.deinit(std.testing.allocator);
    const output = emit_result.output;

    // JSON 내용이 출력에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, output, "\"key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"value\"") != null);
}

// Lazy sourcemap (Issue #1727 Phase B) — eager 와 동일한 JSON 을 생성해야 한다.
// lazy 경로: emit 에서 builder 이관 → caller 가 generateJSON 호출.
// eager 경로: emit 에서 바로 JSON 생성.
// 두 경로의 output 바이트 및 sourcemap JSON 바이트가 완전 동등함을 보장.
test "emitter: lazy_sourcemap 은 eager 경로와 바이트 동등한 JSON 을 생성한다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 42;\nconsole.log(x);\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const base_opts: EmitOptions = .{
        .sourcemap = .{ .enable = true },
        .output_filename = "bundle.js",
    };

    // Eager: emit 단계에서 JSON 생성, sourcemap_builder 는 null.
    var eager_opts = base_opts;
    eager_opts.sourcemap.lazy = false;
    const eager_res = try emit(std.testing.allocator, &result.graph, eager_opts, null);
    defer eager_res.deinit(std.testing.allocator);
    try std.testing.expect(eager_res.sourcemap != null);
    try std.testing.expect(eager_res.sourcemap_builder == null);

    // Lazy: emit 단계에서 builder 이관, sourcemap 은 null.
    var lazy_opts = base_opts;
    lazy_opts.sourcemap.lazy = true;
    const lazy_res = try emit(std.testing.allocator, &result.graph, lazy_opts, null);
    defer lazy_res.deinit(std.testing.allocator);
    try std.testing.expect(lazy_res.sourcemap == null);
    try std.testing.expect(lazy_res.sourcemap_builder != null);

    // Lazy 경로에서 caller 가 직접 generateJSON 호출.
    const lazy_json = try lazy_res.sourcemap_builder.?.generateJSON("bundle.js");

    // 바이트 동등: JSON 과 output(`//# sourceMappingURL=` 주석 포함) 모두.
    try std.testing.expectEqualStrings(eager_res.sourcemap.?, lazy_json);
    try std.testing.expectEqualStrings(eager_res.output, lazy_res.output);
}

test "emitter: lazy_sourcemap 은 sourcemap=false 일 때 builder 도 null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const y = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    // sourcemap.enable=false 면 lazy 플래그는 무시된다 — builder/json 모두 null.
    const res = try emit(std.testing.allocator, &result.graph, .{ .sourcemap = .{ .lazy = true } }, null);
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.sourcemap == null);
    try std.testing.expect(res.sourcemap_builder == null);
}

// ── Issue #1727 Phase B lazy sourcemap 추가 테스트 케이스 ─────────────────────

test "emitter: lazy_sourcemap multi-module 바이트 동등성 (eager vs lazy)" {
    // 여러 모듈 번들에서도 lazy/eager JSON 이 일치하는지 확인.
    // 모듈 경계에서 mapping offset 계산 회귀를 잡는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nconst a: number = 1;\n");
    try writeFile(tmp.dir, "b.ts", "export const b: string = 'hello';\n");
    try writeFile(tmp.dir, "c.ts", "export function greet(name: string) { return `hi ${name}`; }\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const base: EmitOptions = .{ .sourcemap = .{ .enable = true }, .output_filename = "bundle.js" };

    var eager = base;
    eager.sourcemap.lazy = false;
    const eager_res = try emit(std.testing.allocator, &result.graph, eager, null);
    defer eager_res.deinit(std.testing.allocator);

    var lazy = base;
    lazy.sourcemap.lazy = true;
    const lazy_res = try emit(std.testing.allocator, &result.graph, lazy, null);
    defer lazy_res.deinit(std.testing.allocator);

    const lazy_json = try lazy_res.sourcemap_builder.?.generateJSON("bundle.js");
    try std.testing.expectEqualStrings(eager_res.sourcemap.?, lazy_json);
    try std.testing.expectEqualStrings(eager_res.output, lazy_res.output);
}

test "emitter: lazy_sourcemap 에서 sourceMappingURL 주석은 항상 붙는다" {
    // lazy 경로에서도 bungae dev server 가 `/bundle.js.map` 을 serve 하므로 주석이 필요.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true, .lazy = true },
        .output_filename = "bundle.js",
    }, null);
    defer res.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, res.output, "//# sourceMappingURL=bundle.js.map") != null);
}

test "emitter: lazy_sourcemap + debug_ids 는 builder 에 UUID 를 보관한다" {
    // debug_ids 를 lazy 경로에서도 지원. bundle.js 의 `//# debugId=` 주석과 JSON 의 `debugId`
    // 필드가 동일 UUID 로 일치해야 Sentry 매칭이 동작.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true, .lazy = true, .debug_ids = true },
        .output_filename = "bundle.js",
    }, null);
    defer res.deinit(std.testing.allocator);

    // bundle.js 의 `//# debugId=<UUID>` 주석에서 UUID 추출
    const marker = "//# debugId=";
    const idx = std.mem.indexOf(u8, res.output, marker) orelse return error.TestUnexpectedResult;
    const uuid_start = idx + marker.len;
    const uuid_end = std.mem.indexOfScalarPos(u8, res.output, uuid_start, '\n') orelse return error.TestUnexpectedResult;
    const uuid_from_js = res.output[uuid_start..uuid_end];

    // Lazy getter 로 JSON 생성 → 같은 UUID 가 "debugId" 필드로 직렬화
    const json = try res.sourcemap_builder.?.generateJSON("bundle.js");
    const needle = try std.fmt.allocPrint(std.testing.allocator, "\"debugId\":\"{s}\"", .{uuid_from_js});
    defer std.testing.allocator.free(needle);
    try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
}

test "emitter: lazy_sourcemap 은 source_root 를 builder 에 전파" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true, .lazy = true, .source_root = "/src" },
        .output_filename = "bundle.js",
    }, null);
    defer res.deinit(std.testing.allocator);

    const json = try res.sourcemap_builder.?.generateJSON("bundle.js");
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourceRoot\":\"/src\"") != null);
}

test "emitter: lazy_sourcemap 은 sources_content=false 를 반영해 배열 제외" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true, .lazy = true, .sources_content = false },
        .output_filename = "bundle.js",
    }, null);
    defer res.deinit(std.testing.allocator);

    const json = try res.sourcemap_builder.?.generateJSON("bundle.js");
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sourcesContent\"") == null);
}

test "emitter: lazy_sourcemap dev mode — ModuleDevCode.sm_builder 채워지고 map 은 null" {
    // HMR 경로 핵심: collect_module_codes=true + dev_mode=true + lazy=true 조합에서 각
    // ModuleDevCode 가 `sm_builder` 로 전달되고 기존 `map` 필드는 비어 있어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true, .lazy = true },
        .output_filename = "bundle.js",
        .dev_mode = true,
        .collect_module_codes = true,
    }, null);
    defer res.deinit(std.testing.allocator);

    const codes = res.module_codes orelse return error.TestUnexpectedResult;
    try std.testing.expect(codes.len > 0);
    for (codes) |c| {
        try std.testing.expect(c.sm_builder != null);
        try std.testing.expect(c.map == null);
    }
}

test "emitter: per-module sm_builder lazy/eager JSON 바이트 동등" {
    // 동일 입력에 대해 eager(.map) 과 lazy(.sm_builder.generateJSON) 결과가 일치.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 7;\nconsole.log(x);\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const base: EmitOptions = .{
        .sourcemap = .{ .enable = true },
        .output_filename = "bundle.js",
        .dev_mode = true,
        .collect_module_codes = true,
    };

    var eager = base;
    eager.sourcemap.lazy = false;
    const eager_res = try emit(std.testing.allocator, &result.graph, eager, null);
    defer eager_res.deinit(std.testing.allocator);

    var lazy = base;
    lazy.sourcemap.lazy = true;
    const lazy_res = try emit(std.testing.allocator, &result.graph, lazy, null);
    defer lazy_res.deinit(std.testing.allocator);

    const eager_codes = eager_res.module_codes orelse return error.TestUnexpectedResult;
    const lazy_codes = lazy_res.module_codes orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(eager_codes.len, lazy_codes.len);

    for (eager_codes, lazy_codes) |ec, lc| {
        try std.testing.expect(ec.map != null);
        try std.testing.expect(lc.sm_builder != null);
        const lazy_json = try lc.sm_builder.?.generateJSON(lc.id);
        try std.testing.expectEqualStrings(ec.map.?, lazy_json);
    }
}

test "emitter: lazy_sourcemap builder.generateJSON 은 두 번 호출 가능 (재진입)" {
    // NAPI getter 가 여러 번 호출될 수 있으므로 builder state 를 손상시키지 않는지 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true, .lazy = true },
        .output_filename = "bundle.js",
    }, null);
    defer res.deinit(std.testing.allocator);

    const sm = res.sourcemap_builder.?;
    const first = try std.testing.allocator.dupe(u8, try sm.generateJSON("bundle.js"));
    defer std.testing.allocator.free(first);
    const second = try sm.generateJSON("bundle.js");
    try std.testing.expectEqualStrings(first, second);
}

test "emitter: SourceMapOptions 기본값 — 모든 sourcemap 기능 비활성" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    // EmitOptions.{} 기본값에서 sourcemap 은 완전 비활성. output 에 sourceMappingURL 없어야.
    const res = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer res.deinit(std.testing.allocator);
    try std.testing.expect(res.sourcemap == null);
    try std.testing.expect(res.sourcemap_builder == null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "sourceMappingURL") == null);
    try std.testing.expect(std.mem.indexOf(u8, res.output, "debugId") == null);
}

// HMR per-module `//# sourceURL=<mod_id>` 주석 (DevTools VM:1 방지). sourceMappingURL 은
// dev server 가 별도 부착 — 여기서는 sourceURL 만 검증.

test "emitter: dev_mode + sourcemap 활성 시 per-module code 끝에 sourceURL 주석" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true },
        .dev_mode = true,
        .collect_module_codes = true,
    }, null);
    defer res.deinit(std.testing.allocator);

    const codes = res.module_codes orelse return error.TestUnexpectedResult;
    try std.testing.expect(codes.len > 0);
    for (codes) |c| {
        // eval 코드 끝에 `//# sourceURL=<mod_id>` 주석. IIFE `})();\n` 이후에 위치.
        const needle = try std.fmt.allocPrint(std.testing.allocator, "//# sourceURL={s}\n", .{c.id});
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.endsWith(u8, c.code, needle));
    }
}

test "emitter: dev_mode + sourcemap 비활성 시 sourceURL 주석 없음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const res = try emit(std.testing.allocator, &result.graph, .{
        .dev_mode = true,
        .collect_module_codes = true,
    }, null);
    defer res.deinit(std.testing.allocator);

    const codes = res.module_codes orelse return error.TestUnexpectedResult;
    for (codes) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.code, "//# sourceURL=") == null);
    }
}

test "emitter: multi-module 각각에 고유 sourceURL 포함" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const A = 1;\n");
    try writeFile(tmp.dir, "b.ts", "export const B = 2;\n");
    try writeFile(tmp.dir, "entry.ts", "import { A } from './a';\nimport { B } from './b';\nconsole.log(A, B);\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "entry.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true },
        .dev_mode = true,
        .collect_module_codes = true,
    }, null);
    defer res.deinit(std.testing.allocator);

    const codes = res.module_codes orelse return error.TestUnexpectedResult;
    try std.testing.expect(codes.len >= 3);

    // 각 모듈의 sourceURL 이 해당 모듈 path 로 끝나야 한다 (absolute path 포함).
    var seen_a = false;
    var seen_b = false;
    var seen_entry = false;
    for (codes) |c| {
        const needle = try std.fmt.allocPrint(std.testing.allocator, "//# sourceURL={s}\n", .{c.id});
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.endsWith(u8, c.code, needle));
        if (std.mem.endsWith(u8, c.id, "a.ts")) seen_a = true;
        if (std.mem.endsWith(u8, c.id, "b.ts")) seen_b = true;
        if (std.mem.endsWith(u8, c.id, "entry.ts")) seen_entry = true;
    }
    try std.testing.expect(seen_a);
    try std.testing.expect(seen_b);
    try std.testing.expect(seen_entry);
}

test "emitter: root_dir 설정 시 sourceURL 이 상대경로" {
    // dev server / DevTools 가 보기 좋은 경로로 표시하려고 root_dir 을 자주 설정함.
    // sourceURL 값이 절대경로가 아니라 root 기준 상대 — makeModuleId 동작과 일치해야.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;\n");

    const tmp_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_abs);

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true },
        .dev_mode = true,
        .collect_module_codes = true,
        .root_dir = tmp_abs,
    }, null);
    defer res.deinit(std.testing.allocator);

    const codes = res.module_codes orelse return error.TestUnexpectedResult;
    for (codes) |c| {
        // root_dir prefix 가 제거된 상대경로여야 한다.
        try std.testing.expect(!std.mem.startsWith(u8, c.id, tmp_abs));
        try std.testing.expect(std.mem.endsWith(u8, c.id, "index.ts"));
        const needle = try std.fmt.allocPrint(std.testing.allocator, "//# sourceURL={s}\n", .{c.id});
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.endsWith(u8, c.code, needle));
    }
}

test "emitter: collect_module_codes=false — per-module code 자체 미수집 (sourceURL 도 없음)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true },
        .dev_mode = true,
        // collect_module_codes 의도적으로 false.
    }, null);
    defer res.deinit(std.testing.allocator);

    try std.testing.expect(res.module_codes == null);
    // 번들 output 의 sourceMappingURL 은 eager 경로대로 유지 — sourceURL (per-module)
    // 은 module code 가 수집되지 않았으므로 어디에도 없어야.
    try std.testing.expect(std.mem.indexOf(u8, res.output, "//# sourceURL=") == null);
}

test "emitter: sourceURL 은 IIFE 뒤에 위치 — HMR_PREAMBLE_LINES 오프셋 불변" {
    // per-module sourcemap 의 preamble offset 은 hmr_code 앞부분 2줄에 의존.
    // sourceURL 주석이 IIFE 뒤에 와야 mapping offset 이 변하지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;\n");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        m.dev_id = try std.testing.allocator.dupe(u8, m.path);
    }
    defer for (0..result.graph.moduleCount()) |i| {
        const m = result.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.dev_id.len > 0) std.testing.allocator.free(m.dev_id);
        m.dev_id = "";
    };

    const res = try emit(std.testing.allocator, &result.graph, .{
        .sourcemap = .{ .enable = true },
        .dev_mode = true,
        .collect_module_codes = true,
    }, null);
    defer res.deinit(std.testing.allocator);

    const codes = res.module_codes orelse return error.TestUnexpectedResult;
    for (codes) |c| {
        const iife_end = std.mem.indexOf(u8, c.code, "\n})();\n") orelse return error.TestUnexpectedResult;
        const source_url_idx = std.mem.indexOf(u8, c.code, "//# sourceURL=") orelse return error.TestUnexpectedResult;
        try std.testing.expect(source_url_idx > iife_end);
    }
}
