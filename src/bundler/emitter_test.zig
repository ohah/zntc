const std = @import("std");
const emitter = @import("emitter.zig");
const emit = emitter.emit;
const EmitOptions = emitter.EmitOptions;
const appendRuntimeHelpers = emitter.appendRuntimeHelpers;
const RuntimeHelpers = @import("../transformer/transformer.zig").RuntimeHelpers;
const ModuleGraph = @import("graph.zig").ModuleGraph;
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

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{ .minify_whitespace = true }, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .iife }, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .cjs }, null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "\"use strict\";\n"));
}

test "emitter: empty graph" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    const output = try emit(std.testing.allocator, &graph, .{}, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // interface 제거됨
    try std.testing.expect(std.mem.indexOf(u8, output, "interface") == null);
    // enum → IIFE 변환
    try std.testing.expect(std.mem.indexOf(u8, output, "Color") != null);
    // 일반 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, output, "const x") != null);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{entry_path}, null);
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, result.graph.modules.items, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ entry_path, lazy_path }, null);
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ entry_path, pageA_path, pageB_path }, null);
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, result.graph.modules.items, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg1 = try chunk_mod.generateChunks(std.testing.allocator, result1.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg1.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg1, result1.graph.modules.items, std.testing.allocator, null);

    const outputs1 = try emitter.emitChunks(std.testing.allocator, result1.graph.modules.items, &cg1, .{}, null);
    defer {
        for (outputs1) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs1);
    }

    // 두 번째 빌드
    var result2 = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result2.graph.deinit();
    defer result2.cache.deinit();

    var cg2 = try chunk_mod.generateChunks(std.testing.allocator, result2.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg2.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg2, result2.graph.modules.items, std.testing.allocator, null);

    const outputs2 = try emitter.emitChunks(std.testing.allocator, result2.graph.modules.items, &cg2, .{}, null);
    defer {
        for (outputs2) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{entry_path}, null);
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{
        .entry_names = "[name]-[hash]",
    }, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, result.graph.modules.items, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{
        .chunk_names = "chunks/[name]-[hash]",
    }, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, result.graph.modules.items, std.testing.allocator, null);

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{entry_path}, null);
    defer cg.deinit();

    const outputs = try emitter.emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
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
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{}, false);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "appendRuntimeHelpers: extends only" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .extends = true }, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "__generator") == null);
}

test "appendRuntimeHelpers: generator only" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .generator = true }, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "__extends") == null);
}

test "appendRuntimeHelpers: rest only" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .rest = true }, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __rest") != null);
}

test "appendRuntimeHelpers: multiple helpers" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .extends = true, .generator = true, .rest = true }, false);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __extends") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __rest") != null);
}

test "appendRuntimeHelpers: minified" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .generator = true }, true);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "var __generator=function") != null);
    // minified에는 줄바꿈이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\n") == null);
}

test "appendRuntimeHelpers: generator runtime is valid JS" {
    // __generator가 올바른 JS인지 기본 구조 검증
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendRuntimeHelpers(&buf, std.testing.allocator, .{ .generator = true }, false);
    // 핵심 구조 요소 존재 확인
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "label: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Symbol.iterator") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "function verb") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "function step") != null);
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

    const output = try emit(std.testing.allocator, &result.graph, .{
        .banner_js = "/* banner */",
        .footer_js = "/* footer */",
    }, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .banner_js = "// license header",
        .footer_js = "// end",
    }, null);
    defer std.testing.allocator.free(output);

    // banner → IIFE prologue → code → IIFE epilogue → footer
    try std.testing.expect(std.mem.startsWith(u8, output, "// license header\n(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n// end\n"));
}

test "banner/footer — CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{
        .format = .cjs,
        .banner_js = "/* CJS banner */",
    }, null);
    defer std.testing.allocator.free(output);

    // banner가 "use strict" 앞에 위치
    try std.testing.expect(std.mem.startsWith(u8, output, "/* CJS banner */\n\"use strict\";\n"));
}

// ============================================================
// globalName Tests
// ============================================================

test "globalName — IIFE wrapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .global_name = "MyLib",
    }, null);
    defer std.testing.allocator.free(output);

    // prologue: "var MyLib = (function() {\n"
    try std.testing.expect(std.mem.startsWith(u8, output, "var MyLib = (function() {\n"));
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

    const output = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .global_name = "MyApp.Utils",
    }, null);
    defer std.testing.allocator.free(output);

    // 경고 주석이 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, output, "[ZTS WARNING] Dotted globalName") != null);
    // dotted name이면 일반 IIFE로 폴백
    try std.testing.expect(std.mem.indexOf(u8, output, "(function() {\n") != null);
}

test "globalName — ignored for non-IIFE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{
        .format = .esm,
        .global_name = "MyLib",
    }, null);
    defer std.testing.allocator.free(output);

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

    const output = try emit(std.testing.allocator, &result.graph, .{
        .format = .iife,
        .global_name = "MyLib",
        .banner_js = "/* license */",
        .footer_js = "/* end */",
    }, null);
    defer std.testing.allocator.free(output);

    // banner → globalName prologue → code → epilogue → footer
    try std.testing.expect(std.mem.startsWith(u8, output, "/* license */\nvar MyLib = (function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n/* end */\n"));
}

// ============================================================
// JSON Module Tests
// ============================================================

test "JSON module — ESM format" {
    // ESM 포맷 + ESM-only import: scope-hoisted var json_X = {...} 출력.
    // CJS importer가 없으므로 __commonJS 래핑 불필요 (esbuild 동작).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value","num":42}
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .esm }, null);
    defer std.testing.allocator.free(output);

    // ESM-only: scope-hoisted var
    try std.testing.expect(std.mem.indexOf(u8, output, "var json_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"key\":\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var json_data =") != null);
}

test "JSON module — CJS format" {
    // CJS 포맷에서 기존 __commonJS 래핑이 유지되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value"}
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .cjs }, null);
    defer std.testing.allocator.free(output);

    // CJS: __commonJS 래핑 사용
    try std.testing.expect(std.mem.indexOf(u8, output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "require_data") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "module.exports=") != null);
}
