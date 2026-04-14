const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Batch D: metafile, analyze, legal-comments, inject, keepNames
// ============================================================

test "Batch D: metafile — JSON with inputs and outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { add } from './math';\nconsole.log(add(1, 2));");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // metafile JSON이 생성됨
    try std.testing.expect(result.metafile_json != null);
    const mf = result.metafile_json.?;
    // inputs 섹션에 두 모듈 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"inputs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, "entry.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, "math.ts") != null);
    // outputs 섹션 존재
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"outputs\"") != null);
    // import 관계 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"imports\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, "static_import") != null);
    // bytes 필드 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"bytes\"") != null);
}

test "Batch D: metafile — disabled when not requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log(1);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // metafile 미요청 시 null
    try std.testing.expect(result.metafile_json == null);
}

test "Batch D: analyze — forces metafile generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .analyze = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // analyze=true → metafile 자동 활성화
    try std.testing.expect(result.metafile_json != null);
}

test "Batch D: legal-comments=eof — collect at end of output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\/** @license MIT */
        \\console.log("hello");
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .legal_comments = .eof,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // legal comment가 출력 끝에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@license MIT") != null);
    // code가 legal comment보다 앞에 위치
    const code_pos = std.mem.indexOf(u8, result.output, "console.log") orelse 0;
    const license_pos = std.mem.indexOf(u8, result.output, "@license") orelse 0;
    try std.testing.expect(code_pos < license_pos);
}

test "Batch D: legal-comments=none — strip all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\/*! Copyright 2024 */
        \\console.log("hello");
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .legal_comments = .none,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // legal comment 완전 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Copyright") == null);
}

test "Batch D: legal-comments=eof — deduplication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈에 같은 license 주석
    try writeFile(tmp.dir, "a.ts",
        \\/** @license MIT */
        \\export const a = 1;
    );
    try writeFile(tmp.dir, "b.ts",
        \\/** @license MIT */
        \\export const b = 2;
    );
    try writeFile(tmp.dir, "entry.ts", "import { a } from './a';\nimport { b } from './b';\nconsole.log(a, b);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .legal_comments = .eof,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // @license MIT가 1번만 출현 (중복 제거)
    var count: usize = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_pos, "@license MIT")) |pos| {
        count += 1;
        search_pos = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Batch D: inject — prepends injected file before entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shim.js", "globalThis.MY_SHIM = true;");
    try writeFile(tmp.dir, "entry.ts", "console.log(MY_SHIM);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const inject = try absPath(&tmp, "shim.js");
    defer std.testing.allocator.free(inject);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .inject = &.{inject},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shim 코드가 entry보다 먼저 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MY_SHIM = true") != null);
    const shim_pos = std.mem.indexOf(u8, result.output, "MY_SHIM = true") orelse 0;
    const entry_pos = std.mem.indexOf(u8, result.output, "console.log") orelse 0;
    try std.testing.expect(shim_pos < entry_pos);
}

test "Batch D: inject — multiple inject files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shim1.js", "globalThis.A = 1;");
    try writeFile(tmp.dir, "shim2.js", "globalThis.B = 2;");
    try writeFile(tmp.dir, "entry.ts", "console.log(A, B);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const inject1 = try absPath(&tmp, "shim1.js");
    defer std.testing.allocator.free(inject1);
    const inject2 = try absPath(&tmp, "shim2.js");
    defer std.testing.allocator.free(inject2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .inject = &.{ inject1, inject2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 shim 모두 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B = 2") != null);
}

test "Batch D: keepNames — __name call for renamed functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈에서 같은 이름 → linker가 충돌 해결로 rename
    try writeFile(tmp.dir, "a.ts", "export function hello() { return 'a'; }");
    try writeFile(tmp.dir, "b.ts", "export function hello() { return 'b'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\import { hello as ha } from './a';
        \\import { hello as hb } from './b';
        \\console.log(ha(), hb());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 이름 충돌로 rename → __name 호출 삽입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") != null);
    // __name 런타임 헬퍼 주입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var __name") != null);
    // 원본 이름 "hello" 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
}

test "Batch D: keepNames — no __name when names unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "function foo() { return 1; }\nconsole.log(foo());");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 이름 변경 없음 → __name 불필요
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") == null);
}

test "Batch D: keepNames — class declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export class Foo { run() { return 1; } }");
    try writeFile(tmp.dir, "b.ts", "export class Foo { run() { return 2; } }");
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo as A } from './a';
        \\import { Foo as B } from './b';
        \\console.log(new A().run(), new B().run());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // class도 __name 적용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__name(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Foo\"") != null);
}

test "Batch D: keepNames + code splitting — __name helper in chunk" {
    // code splitting + keepNames: 동적 import된 청크에도 __name 런타임 헬퍼가 주입되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const mod = import('./lazy');\nconsole.log(mod);");
    // lazy 청크에 두 개의 같은 이름 함수 → rename 발생
    try writeFile(tmp.dir, "lazy.ts",
        \\import { run } from './util';
        \\export function run() { return 'lazy'; }
        \\console.log(run());
    );
    try writeFile(tmp.dir, "util.ts", "export function run() { return 'util'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .keep_names = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 최소 2개 청크
    try std.testing.expect(outs.len >= 2);

    // __name 호출이 있는 청크에 __name 런타임 헬퍼도 포함되어야 함
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "__name(") != null) {
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "var __name") != null);
        }
    }
}

test "Batch D: legal-comments=eof + minify — comments after minified code" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\/*! MIT License */
        \\export function greet() { return "hi"; }
    );
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './a';\nconsole.log(greet());");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_whitespace = true,
        .minify_syntax = true,
        .legal_comments = .eof,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minified 코드 뒤에 legal comment
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MIT License") != null);
    const code_end = std.mem.indexOf(u8, result.output, "console.log") orelse 0;
    const license_pos = std.mem.indexOf(u8, result.output, "MIT License") orelse 0;
    try std.testing.expect(code_end < license_pos);
}

test "Batch D: metafile — code splitting produces per-chunk outputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const mod = import('./lazy');\nconsole.log(mod);");
    try writeFile(tmp.dir, "lazy.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.metafile_json != null);
    const mf = result.metafile_json.?;
    // code splitting: outputs에 여러 청크 파일 경로 포함
    try std.testing.expect(std.mem.indexOf(u8, mf, "\"outputs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mf, ".js") != null);
}

test "Batch D: inject — inject file included in metafile inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shim.js", "globalThis.X = 1;");
    try writeFile(tmp.dir, "entry.ts", "console.log(X);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const inject = try absPath(&tmp, "shim.js");
    defer std.testing.allocator.free(inject);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .inject = &.{inject},
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.metafile_json != null);
    // inject 파일도 metafile inputs에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.metafile_json.?, "shim.js") != null);
}

// ============================================================
// Web Worker auto-bundling
// ============================================================

test "Worker: new Worker(new URL) produces separate IIFE bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w = new Worker(new URL('./worker.ts', import.meta.url));
        \\w.postMessage('hi');
    );
    try writeFile(tmp.dir, "worker.ts",
        \\self.onmessage = (e) => self.postMessage('pong');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 메인 번들에 worker URL이 교체됨 (new URL 대신 문자열)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".js\")") != null);
    // new URL이 사라짐
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(") == null);

    // worker 번들이 asset_outputs에 포함
    try std.testing.expect(result.asset_outputs != null);
    const assets = result.asset_outputs.?;
    try std.testing.expect(assets.len >= 1);

    // worker 번들이 IIFE로 래핑
    var found_worker = false;
    for (assets) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-")) {
            found_worker = true;
            try std.testing.expect(std.mem.indexOf(u8, a.contents, "self.onmessage") != null);
            try std.testing.expect(std.mem.startsWith(u8, a.contents, "(function() {"));
        }
    }
    try std.testing.expect(found_worker);
}

test "Worker: no Worker pattern means no extra assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1; console.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // worker가 없으면 asset_outputs가 null
    try std.testing.expect(result.asset_outputs == null);
}

test "Worker: multiple workers produce separate bundles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w1 = new Worker(new URL('./worker-a.ts', import.meta.url));
        \\const w2 = new Worker(new URL('./worker-b.ts', import.meta.url));
        \\w1.postMessage('a');
        \\w2.postMessage('b');
    );
    try writeFile(tmp.dir, "worker-a.ts", "self.onmessage = (e) => self.postMessage('a');");
    try writeFile(tmp.dir, "worker-b.ts", "self.onmessage = (e) => self.postMessage('b');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 두 worker URL이 모두 교체됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-a-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-b-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(") == null);

    // 2개 worker 번들이 asset_outputs에 포함
    try std.testing.expect(result.asset_outputs != null);
    try std.testing.expect(result.asset_outputs.?.len >= 2);

    var found_a = false;
    var found_b = false;
    for (result.asset_outputs.?) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-a-")) found_a = true;
        if (std.mem.startsWith(u8, a.path, "worker-b-")) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

test "Worker: duplicate references to same worker build only once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w1 = new Worker(new URL('./worker.ts', import.meta.url));
        \\const w2 = new Worker(new URL('./worker.ts', import.meta.url));
        \\w1.postMessage('first');
        \\w2.postMessage('second');
    );
    try writeFile(tmp.dir, "worker.ts", "self.onmessage = (e) => self.postMessage('ok');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 두 참조 모두 같은 파일명으로 교체
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(\"./worker-") != null);
    // new URL은 전부 사라짐
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(") == null);

    // asset_outputs에 worker 번들 1개만 (중복 빌드 방지)
    try std.testing.expect(result.asset_outputs != null);
    var worker_count: usize = 0;
    for (result.asset_outputs.?) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-")) worker_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), worker_count);
}

test "Worker: SharedWorker is also detected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const sw = new SharedWorker(new URL('./shared.ts', import.meta.url));
        \\sw.port.postMessage('hi');
    );
    try writeFile(tmp.dir, "shared.ts", "self.onconnect = (e) => {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new SharedWorker(\"./shared-") != null);
    try std.testing.expect(result.asset_outputs != null);
}

// ============================================================
// None-node crash prevention: parse errors must not crash transformer/codegen
// Previously, modules with parse errors had incomplete ASTs containing
// .none (0xFFFFFFFF) node indices, causing index-out-of-bounds panics.
// ============================================================

test "Bundle: Flow file with parse errors does not crash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Entry imports a Flow file with import typeof (requires --flow or @flow pragma)
    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./lib');
        \\console.log(x);
    );
    // Flow file with @flow pragma and import typeof — Flow type-only import
    try writeFile(tmp.dir, "lib.js",
        \\// @flow
        \\import typeof * as API from './api';
        \\module.exports = { value: 42 };
    );
    try writeFile(tmp.dir, "api.js",
        \\module.exports = {};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // Should not crash — either succeeds or reports errors gracefully
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Bundle: Flow export type alias + module.exports → CJS wrapping (#713)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./lib');
        \\console.log(x);
    );
    // Flow: import typeof + export type alias + module.exports 혼합
    // ReactNativePrivateInterface.js 패턴 — type-only export가 ESM 신호로 잘못 판별되면
    // __esm 래핑되어 module 변수 미정의 런타임 에러 발생
    try writeFile(tmp.dir, "lib.js",
        \\// @flow strict-local
        \\import typeof Foo from './dep';
        \\export type Bar = string;
        \\export type {Foo};
        \\module.exports = { value: 42 };
    );
    try writeFile(tmp.dir, "dep.js",
        \\module.exports = {};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS 모듈이므로 __commonJS로 래핑되어야 함 (__esm이 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "Bundle: TS export type alias + module.exports → CJS wrapping (#713)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const x = require('./lib');
        \\console.log(x);
    );
    // TS: export type alias + export interface + module.exports 혼합
    try writeFile(tmp.dir, "lib.ts",
        \\export type Foo = string;
        \\export interface Bar { x: number; }
        \\module.exports = { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS 모듈이므로 __commonJS로 래핑되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "Bundle: Flow export opaque type + module.exports → CJS wrapping (#713)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./lib');
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.js",
        \\// @flow
        \\export opaque type ID = string;
        \\module.exports = { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "Bundle: module with syntax errors does not crash transformer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Entry file is valid
    try writeFile(tmp.dir, "entry.js",
        \\const x = require('./broken');
        \\console.log(x);
    );
    // Broken file with intentional syntax error
    try writeFile(tmp.dir, "broken.js",
        \\export const x = {
        \\  a: 1,
        \\  ...  // incomplete spread — parse error
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // Should not crash — broken module is skipped, bundle still produced
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

// ============================================================
// __esm live binding 테스트 (rolldown 방식)
// ============================================================

test "ESM live binding: function hoisted outside __esm references canonical var" {
    // __esm 모듈의 function이 다른 __esm 모듈의 변수를 참조할 때,
    // function은 밖에 호이스팅되고 canonical 변수를 직접 참조해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "style.js",
        \\export var color = 'red';
    );
    try writeFile(tmp.dir, "component.js",
        \\import { color } from './style.js';
        \\export function getColor() { return color; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./component.js');
        \\console.log(m.getColor());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // function이 __esm 밖에 호이스팅
    const esm_start = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const fn_pos = std.mem.indexOf(u8, result.output, "function getColor()") orelse unreachable;
    try std.testing.expect(fn_pos < esm_start);
    // live binding: component.js의 __esm init에 import 스냅샷 할당이 없어야 함.
    // init에는 init_xxx() 호출만 있고 __toCommonJS 패턴이 없어야 함.
    const component_init = std.mem.indexOf(u8, result.output, "\"component.js\"()") orelse unreachable;
    // init body는 다음 }); 까지
    const init_end = std.mem.indexOf(u8, result.output[component_init..], "\n\t}\n});") orelse
        std.mem.indexOf(u8, result.output[component_init..], "}});") orelse unreachable;
    const init_body = result.output[component_init .. component_init + init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_body, "__toCommonJS") == null);
}

test "ESM live binding: init only contains dependency init calls" {
    // __esm → __esm import 시, init 함수에는 의존 init 호출만 있어야 함.
    // 스냅샷 할당 코드(= (init_xxx(), __toCommonJS(exports_xxx)).xxx)가 없어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.js",
        \\export const value = 42;
    );
    try writeFile(tmp.dir, "mod.js",
        \\import { value } from './dep.js';
        \\export function getValue() { return value; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\const d = require('./dep.js');
        \\console.log(m.getValue(), d.value);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // mod.js의 init에 init_dep 호출이 있어야 함
    const mod_init = std.mem.indexOf(u8, result.output, "\"mod.js\"()") orelse unreachable;
    const init_end2 = std.mem.indexOf(u8, result.output[mod_init..], "\n\t}\n});") orelse
        std.mem.indexOf(u8, result.output[mod_init..], "}});") orelse unreachable;
    const mod_body = result.output[mod_init .. mod_init + init_end2];
    try std.testing.expect(std.mem.indexOf(u8, mod_body, "init_") != null);
    // init 안에 __toCommonJS 스냅샷 복사가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, mod_body, "__toCommonJS") == null);
}

test "ESM live binding: namespace import uses exports_xxx (not live binding)" {
    // namespace import(import * as X)는 exports_xxx로 rename되어야 함.
    // 이 import_declaration은 body codegen에서 할당문으로 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.js",
        \\export function add(a, b) { return a + b; }
        \\export function sub(a, b) { return a - b; }
    );
    try writeFile(tmp.dir, "mod.js",
        \\import * as Utils from './utils.js';
        \\export default Utils.add(1, 2);
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\console.log(m.default);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace import는 exports_xxx로 참조
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_") != null);
}

test "ESM live binding: re-export from __esm uses source canonical name" {
    // re-export(export { X } from './dep')에서 __esm 타겟의 canonical name을 사용해야 함.
    // __export getter가 올바른 변수를 참조.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "impl.js",
        \\export function doWork() { return 'done'; }
    );
    try writeFile(tmp.dir, "facade.js",
        \\export { doWork } from './impl.js';
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./facade.js');
        \\console.log(m.doWork());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // facade.js의 __export getter가 doWork를 참조 (undefined가 아닌 실제 함수)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "doWork") != null);
    // function doWork이 번들에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function doWork()") != null);
}

test "ESM live binding: class stays inside __esm init (block-scoped)" {
    // class는 block-scoped이므로 __esm init 안에 할당문으로 유지되어야 함.
    // function과 다르게 밖으로 호이스팅되면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\export class Greeter {
        \\  greet() { return 'hello'; }
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\console.log(new m.Greeter().greet());
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const esm_start = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    // class는 할당문으로 __esm 안에 있어야 함
    const class_pos = std.mem.indexOf(u8, result.output, "Greeter = class") orelse unreachable;
    try std.testing.expect(class_pos > esm_start);
}

test "ESM live binding: RN platform forces __esm wrapping with live binding" {
    // --platform=react-native 시 모든 비-엔트리 ESM 모듈이 __esm 래핑되고,
    // 모듈 간 import가 live binding으로 처리되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "helper.js",
        \\export function format(s) { return '[' + s + ']'; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { format } from './helper.js';
        \\console.log(format('test'));
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm 래핑이 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm({") != null);
    // function이 __esm 밖에 호이스팅
    const esm_pos = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const fn_pos = std.mem.indexOf(u8, result.output, "function format(") orelse unreachable;
    try std.testing.expect(fn_pos < esm_pos);
    // helper.js의 init에 __toCommonJS 스냅샷 없음
    // (엔트리에서 require() 시 __toCommonJS가 사용될 수 있지만, 모듈 간 import에는 없어야 함)
    const helper_init = std.mem.indexOf(u8, result.output, "\"helper.js\"()") orelse unreachable;
    const helper_end = std.mem.indexOf(u8, result.output[helper_init..], "\n\t}\n});") orelse
        std.mem.indexOf(u8, result.output[helper_init..], "}});") orelse unreachable;
    const helper_body = result.output[helper_init .. helper_init + helper_end];
    try std.testing.expect(std.mem.indexOf(u8, helper_body, "__toCommonJS") == null);
}

// ============================================================
// JSX Automatic Import Injection
// ============================================================

test "JSX automatic: jsx-runtime import injected in bundle mode" {
    // --jsx=automatic 사용 시 react/jsx-runtime에서 _jsx, _jsxs, _Fragment import가 주입되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div><span>Hello</span></div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // _jsx가 react/jsx-runtime에서 import되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") != null);
    // React.createElement가 아닌 _jsx 호출이어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "React.createElement") == null);
}

test "JSX automatic-dev: jsx-dev-runtime import injected in bundle mode" {
    // --jsx-dev 사용 시 react/jsx-dev-runtime에서 _jsxDEV import가 주입되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // _jsxDEV가 react/jsx-dev-runtime에서 import되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-dev-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV") != null);
}

test "JSX automatic: no injection when no JSX in module" {
    // JSX가 없는 모듈에서는 jsx-runtime import가 주입되지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const x = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // jsx-runtime 관련 코드가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "jsx-runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") == null);
}

test "JSX automatic: classic mode does not inject jsx-runtime" {
    // --jsx=classic 사용 시 jsx-runtime import가 주입되지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .classic,
        .external = &.{"react"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // classic 모드에서는 React.createElement 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "jsx-runtime") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") != null);
}

test "JSX automatic: custom import source" {
    // --jsx-import-source=preact 사용 시 preact/jsx-runtime에서 import되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .jsx_import_source = "preact",
        .external = &.{"preact/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // preact/jsx-runtime에서 import되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "preact/jsx-runtime") != null);
    // "react/jsx-runtime"이 아닌 "preact/jsx-runtime"이어야 함
    // (preact에 react가 부분 문자열로 포함되므로, require("react/jsx-runtime") 정확히 검사)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"react/jsx-runtime\")") == null);
}

test "JSX automatic: ESM-wrapped module with CJS jsx-runtime — synthetic binding not skipped" {
    // ESM-wrapped 모듈(require()로 소비되는 ESM)에서 CJS jsx-runtime import 시
    // synthetic JSX binding이 linker의 ESM+CJS skip에 걸리지 않고 preamble에 emit되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // app.tsx: ESM syntax (export) + JSX → require로 소비되면 ESM-wrapped
    try writeFile(tmp.dir, "app.tsx",
        \\export function App() { return <div>Hello</div>; }
    );
    // entry.ts: require로 app.tsx를 소비 → app.tsx가 ESM-wrapped
    try writeFile(tmp.dir, "entry.ts",
        \\const app = require('./app.tsx');
        \\console.log(app.App());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM-wrapped 모듈임을 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") != null);
    // _jsxDEV 바인딩이 생성되어야 함 (ESM+CJS skip에 걸리지 않음)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-dev-runtime") != null);
}

test "JSX automatic-dev: #1209 — _jsxDEV must be assigned per module (HMR safety)" {
    // Issue #1209 재현: ESM-wrapped 멀티 모듈 번들에서 각 모듈 init 함수가
    // `var _jsxDEV, _Fragment;` 선언만 하고 실제 할당이 누락 → HMR 재실행 시
    // `_jsxDEV is not a function` 에러 발생.
    //
    // 검증: _jsxDEV 바인딩 할당이 번들에 존재해야 함 (선언만으로는 부족).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "App.tsx",
        \\import { Header } from './Header';
        \\export function App() { return <div><Header /></div>; }
    );
    try writeFile(tmp.dir, "Header.tsx",
        \\export function Header() { return <header>H</header>; }
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { App } from './App';
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    // RN 시나리오: platform=react-native + IIFE + external
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .platform = .react_native,
        .format = .iife,
        .external = &.{ "react/jsx-dev-runtime", "react" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    const out = result.output;

    try std.testing.expect(std.mem.indexOf(u8, out, "_jsxDEV(") != null);

    // 버그 #1209: __esm init 함수 내부에서 `var _jsxDEV = ...`로 emit되면
    // outer scope의 `var _jsxDEV`를 shadow → Header() 함수에서 항상 undefined.
    // 올바른 emit: `_jsxDEV = ...` (var 없이, outer 바인딩에 할당).
    try std.testing.expect(std.mem.indexOf(u8, out, "var _jsxDEV = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var _Fragment = ") == null);

    // outer scope의 `var ..., _jsxDEV, _Fragment;` 선언은 존재해야 함
    // (또는 ESM-wrap가 아닌 평면 스코프면 단일 var로 합쳐질 수 있음)
    try std.testing.expect(std.mem.indexOf(u8, out, "_jsxDEV") != null);
    // init 함수 본문에 `_jsxDEV = ` (var 없이) 할당이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, out, "_jsxDEV = require") != null or
        std.mem.indexOf(u8, out, "jsxDEV: _jsxDEV") != null);
}

test "JSX automatic-dev: #1209 — browser platform also affected" {
    // 웹 환경(browser) + require 소비로 ESM-wrap 강제되는 경우에도 동일 버그.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\export function App() { return <div>hi</div>; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\const m = require('./app.tsx');
        \\console.log(m.App());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .platform = .browser,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    const out = result.output;
    // ESM-wrapped 확인
    try std.testing.expect(std.mem.indexOf(u8, out, "__esm(") != null);
    // 같은 버그: `var _jsxDEV = ...`로 outer를 shadow하면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, out, "var _jsxDEV = ") == null);
}

test "JSX automatic: multiple modules sharing same jsx-runtime" {
    // 여러 모듈이 같은 jsx-runtime을 import할 때, 각 모듈에 바인딩이 독립적으로 생성되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "comp_a.tsx",
        \\export function CompA() { return <span>A</span>; }
    );
    try writeFile(tmp.dir, "comp_b.tsx",
        \\export function CompB() { return <span>B</span>; }
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { CompA } from './comp_a.tsx';
        \\import { CompB } from './comp_b.tsx';
        \\export function App() { return <div><CompA /><CompB /></div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // jsx-runtime이 번들에 참조됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react/jsx-runtime") != null);
    // 모든 컴포넌트가 _jsx로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(CompA") != null or
        std.mem.indexOf(u8, result.output, "_jsx(CompB") != null);
    // React.createElement가 아닌 _jsx 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") == null);
}

test "JSX automatic: fragment syntax uses _Fragment" {
    // <> </> fragment 구문이 _Fragment로 변환되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <><span>A</span><span>B</span></>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // _Fragment가 사용되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_Fragment") != null);
    // _jsxs (static children — 여러 자식)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxs(") != null);
}

test "JSX automatic-dev: source location info included" {
    // --jsx-dev 모드에서 fileName, lineNumber, columnNumber가 포함되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // dev 모드: 소스 위치 정보 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fileName") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lineNumber") != null);
}

test "JSX automatic: mixed JSX and non-JSX modules" {
    // JSX가 있는 모듈에만 jsx-runtime import가 주입되고, 없는 모듈에는 주입되지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts",
        \\export function add(a: number, b: number) { return a + b; }
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { add } from './util.ts';
        \\export function App() { return <div>{add(1, 2)}</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry.tsx에서 _jsx 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(\"div\"") != null);
    // util.ts의 add 함수가 정상 번들됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "add(") != null);
}

test "JSX automatic: re-export of JSX component" {
    // JSX 컴포넌트를 re-export하는 배럴 파일이 정상 동작해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "button.tsx",
        \\export function Button() { return <button>Click</button>; }
    );
    try writeFile(tmp.dir, "index.ts",
        \\export { Button } from './button.tsx';
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { Button } from './index.ts';
        \\export function App() { return <div><Button /></div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈 모두 _jsx 사용 (button.tsx + entry.tsx)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx(Button") != null);
}

test "JSX automatic: ESM-wrapped hoisted function can access _jsxDEV (scope test)" {
    // ESM-wrapped 모듈에서 function이 __esm 밖으로 호이스팅될 때,
    // _jsxDEV가 top-level var로 선언되어야 호이스팅된 함수에서 접근 가능.
    // 이전 버그: _jsxDEV가 __esm init 블록 안 지역변수로 선언되어 ReferenceError.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Comp() { return <div>Hello</div>; }
    );
    // require()로 소비하여 comp.tsx를 ESM-wrapped로 만듦
    try writeFile(tmp.dir, "entry.ts",
        \\const c = require('./comp.tsx');
        \\console.log(c.Comp());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm으로 래핑됨을 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") != null);
    // _jsxDEV가 top-level에 선언 (호이스팅된 함수에서 접근 가능).
    // esm_wrap emit은 `var <...>, _jsxDEV, _Fragment;` 형태로 병합 선언하므로
    // 선언 존재는 `, _jsxDEV` 토큰으로 확인.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV") != null);
    // 호이스팅된 function이 _jsxDEV를 사용 (React.createElement가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV(\"div\"") != null);
    // #1209: __esm init 안에서는 `var` 없이 할당만 (outer scope 재선언 금지)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxDEV = require") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var _jsxDEV = require") == null);
}

test "JSX automatic: ESM-wrapped with multiple JSX functions (_jsx, _jsxs, _Fragment)" {
    // ESM-wrapped 모듈에서 _jsx, _jsxs, _Fragment 모두 top-level 선언되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Comp() {
        \\  return <><div>A</div><span>B</span></>;
        \\}
    );
    try writeFile(tmp.dir, "entry.ts",
        \\const c = require('./comp.tsx');
        \\console.log(c.Comp());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 JSX 함수가 top-level에 선언됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_Fragment") != null);
    // Fragment + 여러 children → _jsxs 사용
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsxs(_Fragment") != null);
}

test "JSX automatic: non-ESM-wrapped module still uses var declaration" {
    // ESM-wrapped가 아닌 일반 모듈에서는 preamble에 var _jsx = ... 형태 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App() { return <div>Hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm이 아님 (일반 scope-hoisted)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") == null);
    // var _jsx = require(...) 형태 (var 포함)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var _jsx") != null);
}

// ============================================================
// Runtime helper: __copyProps / __toCommonJS (rolldown 호환)
// ============================================================

test "runtime helper: __copyProps uses getOwnPropertyNames, not Object.keys" {
    // ESM에서 CJS를 import할 때 __toESM → __copyProps가 주입됨.
    // __copyProps가 getOwnPropertyNames를 사용하여 non-enumerable 프로퍼티도 복사하는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ESM entry가 CJS를 import → __toESM/__copyProps 필요
    try writeFile(tmp.dir, "entry.ts", "import greet from './cjs-mod.js';\nconsole.log(greet());");
    try writeFile(tmp.dir, "cjs-mod.js",
        \\module.exports = function greet() { return 'hello'; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // getOwnPropertyNames 사용 확인 (Object.keys가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyNames") != null);
    // getOwnPropertyDescriptor로 enumerable 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getOwnPropertyDescriptor") != null);
    // __copyProps 정의 부분에서 Object.keys가 없는지 확인
    if (std.mem.indexOf(u8, result.output, "__copyProps")) |cp_pos| {
        const end = @min(cp_pos + 300, result.output.len);
        const slice = result.output[cp_pos..end];
        try std.testing.expect(std.mem.indexOf(u8, slice, "Object.keys") == null);
    }
    // bind(null, key) 패턴으로 var 루프에서 key 고정 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".bind(null,") != null or
        std.mem.indexOf(u8, result.output, ".bind(null, ") != null);
}

test "runtime helper: __toCommonJS has module.exports direct return path" {
    // ESM 모듈이 CJS로 소비될 때 __toCommonJS가 주입됨.
    // __commonJS로 래핑된 모듈은 module.exports를 직접 반환하여 getter를 보존해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // CJS entry가 ESM을 require → __esm + __toCommonJS 필요
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm-mod.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "esm-mod.js",
        \\export const value = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __toCommonJS 헬퍼가 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS") != null);
    // module.exports 직접 반환 경로가 있어야 함 (rolldown 방식)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

// ============================================================
// RN 엔트리 __esm 래핑 (Rolldown 호환 초기화 순서 보장)
// ============================================================

test "RN platform: entry module is __esm wrapped (not scope-hoisted)" {
    // RN에서 엔트리도 __esm 래핑되어야 circular dep 초기화 순서가 보장됨.
    // Rolldown 방식: 번들 끝에 init_entry()를 호출하여 실행 시작.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { View } from './view.js';
        \\console.log(View);
    );
    try writeFile(tmp.dir, "view.js",
        \\export const View = "MockView";
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 엔트리가 __esm 래핑됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_index = __esm(") != null or
        std.mem.indexOf(u8, result.output, "init_entry = __esm(") != null);
    // 번들 끝에 init_xxx() 호출이 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_index();\n") != null or
        std.mem.indexOf(u8, result.output, "init_entry();\n") != null);
    // top-level var View = require_xxx().View 패턴이 없어야 함 (즉시 평가 방지)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var View = require_") == null);
}

test "RN platform: entry __esm contains import bindings inside init body" {
    // 엔트리의 import 바인딩이 __esm body 안에 있어야 함 (lazy 평가).
    // top-level에 var X = require_Y().X 형태로 노출되면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add, PI } from './math.js';
        \\console.log(add(1, 2), PI);
    );
    try writeFile(tmp.dir, "math.js",
        \\exports.add = function(a, b) { return a + b; };
        \\exports.PI = 3.14;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 엔트리가 __esm 래핑됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_entry = __esm(") != null);
    // __esm body 안에서 require_math() 호출이 있어야 함 (lazy 평가)
    // __esm body는 "entry.ts"() { ... } 형태
    const body_start = std.mem.indexOf(u8, result.output, "\"entry.ts\"()") orelse {
        return error.TestUnexpectedResult;
    };
    const body_slice = result.output[body_start..];
    // body 안에서 require_math() 호출 확인
    try std.testing.expect(std.mem.indexOf(u8, body_slice, "require_math()") != null);
    // init_entry() 호출이 번들 끝에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_entry();\n") != null);
}

test "non-RN platform: entry is NOT __esm wrapped (scope-hoisted)" {
    // browser/node 플랫폼에서는 엔트리가 scope-hoisted로 유지되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './mod.js';
        \\console.log(greet());
    );
    try writeFile(tmp.dir, "mod.js",
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 엔트리는 __esm 래핑 안 됨 (기본 browser 플랫폼)
    // init_entry() 호출이 번들 끝에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_entry()") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_index()") == null);
}

// ============================================================
// Namespace inline 객체: getter live binding (Rolldown 호환)
// ============================================================

test "namespace inline object uses getter for live binding" {
    // import * as X를 값으로 사용할 때, 인라인 객체가 getter로 생성되어야 함.
    // circular dep에서 init 시점에 undefined인 변수도 사용 시점에 올바르게 참조.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as mod from './mod.js';\nexport { mod };\nconsole.log(mod.greet());");
    try writeFile(tmp.dir, "mod.js",
        \\export function greet() { return 'hello'; }
        \\export const PI = 3.14;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // getter 형태: get greet() { return ...; }
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get greet()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get PI()") != null);
    // 값 복사 형태가 아님: greet: greet (이건 없어야 함)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "greet: greet") == null);
}

test "namespace inline object: default export quoted in getter" {
    // default는 JS 예약어이므로 get "default"() 형태로 따옴표 필요.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as mod from './mod.js';\nexport { mod };\nconsole.log(mod.default);");
    try writeFile(tmp.dir, "mod.js",
        \\const val = 42;
        \\export default val;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // default가 따옴표로 감싸져야 함: get "default"()
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get \"default\"()") != null);
    // bare default가 값 위치에 나타나면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": default,") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": default}") == null);
}

// === self-require / self-re-export 테스트 ===

test "Self-require: RN 플랫폼 파일 패턴 (조건부 self-require)" {
    // ProgressBarAndroid.js 패턴: if (condition) require('./self')
    // resolver가 같은 파일로 resolve할 때 init 재귀 호출이 발생하면 안 됨.
    // CJS 모듈에서 자기 자신을 require하는 패턴.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Widget } from './widget';
        \\console.log(Widget);
    );
    // widget.js: CJS 모듈이 조건부로 자기 자신을 require
    try writeFile(tmp.dir, "widget.js",
        \\let Widget;
        \\if (typeof globalThis !== 'undefined') {
        \\  Widget = require('./widget').default;
        \\} else {
        \\  Widget = 'fallback';
        \\}
        \\module.exports = Widget;
        \\module.exports.default = Widget;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // self-require는 module.exports로 변환되어야 함 (require 재귀 호출 없이)
    // 번들에 raw require('./widget')가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./widget\")") == null);
}

test "shimMissingExports: missing export에 shim 변수 생성" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { nonExistent } from './lib';
        \\console.log(nonExistent);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const existing = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .shim_missing_exports = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shim 변수가 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "void 0") != null);
    // console.log이 참조 에러 없이 출력 가능
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "shimMissingExports: 플래그 꺼져있으면 shim 미생성" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { nonExistent } from './lib';
        \\console.log(nonExistent);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const existing = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .shim_missing_exports = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shim 없으면 void 0 선언이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "void 0") == null);
}

test "Self-re-export: default re-export가 자기 자신을 가리킬 때 skip" {
    // Platform.js 패턴: import X from './self'; export default X;
    // resolve가 같은 파일을 가리키면 re-export 코드에서 init 자기호출 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import val from './proxy';
        \\console.log(val);
    );
    // proxy.ts가 자기 자신을 import해서 re-export
    try writeFile(tmp.dir, "proxy.ts",
        \\import X from './proxy';
        \\export default X;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 자기참조 re-export는 에러가 아닌 경고 → 번들 생성 성공
    try std.testing.expect(!result.hasErrors());
    // __esm init 안에서 자기 init을 호출하면 안 됨.
    // init_proxy가 2회 이상 나타나면 자기참조가 있다는 뜻
    // (1회는 `var init_proxy = __esm(` 선언 자체).
    const output = result.output;
    var init_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, output, search_from, "init_proxy")) |pos| {
        init_count += 1;
        search_from = pos + "init_proxy".len;
    }
    // 선언 1회만 허용 — body 안에서 자기호출이 있으면 2회 이상
    try std.testing.expect(init_count <= 1);
}

test "__rest: Symbol 프로퍼티 복사 포함" {
    // TypeScript __rest 호환: Object.getOwnPropertySymbols로 Symbol도 복사
    // runtime_helpers의 REST_RUNTIME 문자열을 직접 검증
    const runtime = @import("../runtime_helpers.zig");
    try std.testing.expect(std.mem.indexOf(u8, runtime.REST_RUNTIME, "getOwnPropertySymbols") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.REST_RUNTIME, "propertyIsEnumerable") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.REST_RUNTIME_MIN, "getOwnPropertySymbols") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.REST_RUNTIME_MIN, "propertyIsEnumerable") != null);
}

test "let → var: 초기화 없는 let에 void 0 추가 확인" {
    // RN Fabric 레이아웃 버그의 근본 원인: let → var 변환 시 = void 0 누락으로
    // for 루프에서 이전 반복의 값이 유지되어 style prop이 오염됨.
    // runtime_helpers의 __rest에 void 0 패턴이 있는지로 간접 검증 대신,
    // 트랜스포머가 void 0을 생성하는지 codegen_test에서 직접 검증 (4개 테스트 추가됨).
    // 여기서는 변환 로직의 핵심 경로만 확인.
    const block_scoping = @import("../../transformer/es2015_block_scoping.zig");
    // let(1) → var(0)
    try std.testing.expectEqual(@as(u32, 0), block_scoping.lowerKindFlags(1));
    // const(2) → var(0)
    try std.testing.expectEqual(@as(u32, 0), block_scoping.lowerKindFlags(2));
    // var(0) → var(0) 그대로
    try std.testing.expectEqual(@as(u32, 0), block_scoping.lowerKindFlags(0));
}

// ============================================================
// RN preset: platform=react-native → Hermes unsupported matrix 강제 적용
// ============================================================

test "RN preset: class → function IIFE 강제 다운레벨 (Hermes class expression 호환)" {
    // Hermes는 __esm wrap 내부의 `X = class X {}` 형태 class expression을 거부한다.
    // platform=react-native 프리셋은 자동으로 `unsupported.class = true`를 설정해
    // class를 function + prototype으로 다운레벨한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\import { AppError } from './err.js';
        \\console.log(new AppError('x'));
    );
    try writeFile(tmp.dir, "err.js",
        \\export class AppError extends Error {
        \\  constructor(msg) { super(msg); }
        \\}
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // class expression이 emit되지 않아야 함 (Hermes 호환의 핵심)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "= class AppError") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=class AppError") == null);
    // class → function 변환 런타임 헬퍼가 주입돼야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classCallCheck") != null);
}

test "RN preset: 사용자 unsupported.class=false여도 RN에서 자동 true 오버라이드" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\class Foo { greet() { return 'hi'; } }
        \\new Foo().greet();
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    // 사용자가 의도적으로 class 보존을 요청해도 RN 프리셋이 오버라이드
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .unsupported = .{ .class = false },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // RN에서는 class가 남아 있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "= class Foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=class Foo") == null);
}

test "RN preset: browser 플랫폼에서는 class 그대로 보존" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\class Foo { greet() { return 'hi'; } }
        \\new Foo().greet();
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // browser는 class 문법 지원 → 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classCallCheck") == null);
}

test "RN preset: async/await은 보존 (Hermes native 지원)" {
    // #1267 회귀 방지: RN 프리셋이 async를 state machine으로 변환하지 않아야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\export async function f() { return await Promise.resolve(1); }
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // async/await 그대로 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await ") != null);
    // state machine 헬퍼 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__generator") == null);
}
