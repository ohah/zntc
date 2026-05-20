const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const rt = @import("../runtime_helpers.zig");
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

/// `react_native inlineRequires:` 테스트들이 잠그는 lazy ESM import emit 패턴 —
/// `(__zntc_guarded(function(){return __zntc_modules["<path>"].fn()}), <binding>).<member>`
/// 형태. caller 는 free 책임 (returned slice 는 allocator 소유).
///
/// - `assign_to == ""` — bare lazy expression marker (`"...modules[...]..fn()}}), TOKENS).primary"`).
///   raw bare `TOKENS.primary` 가 어디에도 없는지 확인할 때 contains 매칭용.
/// - `assign_to != ""` — assignment form (`"name=(__zntc_guarded(...)).primary"`).
///   class lowering 으로 default 가 풀려나가는 케이스에는 부적합 — bare form 사용.
fn formatLazyMarker(
    allocator: std.mem.Allocator,
    assign_to: []const u8,
    module_path: []const u8,
    binding: []const u8,
    member: []const u8,
) ![]const u8 {
    if (assign_to.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "{s}__zntc_modules[\"{s}\"].fn()}}), {s}).{s}",
            .{ rt.GUARD_LAMBDA_OPEN, module_path, binding, member },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}=({s}__zntc_modules[\"{s}\"].fn()}}), {s}).{s}",
        .{ assign_to, rt.GUARD_LAMBDA_OPEN, module_path, binding, member },
    );
}

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

test "Batch D: metafile — virtual specifier (NUL byte) JSON-escape" {
    // Regression: ZNTC runtime helper virtual specifier (NUL + "zntc:runtime/...") 가
    // raw NUL 그대로 metafile JSON 에 들어가 JSON.parse 가 "Bad control character" 로 reject.
    // RN 통합 테스트 (`Metro 모듈 수 기준선`) 가 meta.json 파싱 실패로 깨짐.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export function f({ a, ...rest }: any) { return rest; }
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        // ES5 → object rest spread 가 `__rest` runtime helper 로 다운레벨링되어
        // ZNTC virtual specifier "zntc:runtime/rest" 가 graph 에 등록됨.
        .unsupported = @import("../../transformer/compat.zig").fromESTarget(.es5),
        .metafile = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const mf = result.metafile_json orelse return error.TestUnexpectedResult;
    // raw NUL 절대 포함되면 안 됨 — JSON.parse 에서 reject.
    try std.testing.expect(std.mem.indexOfScalar(u8, mf, 0x00) == null);
    // 어떤 형태로든 NUL escape 되어야 — `zntc:runtime/rest` 형태로 emit.
    try std.testing.expect(std.mem.indexOf(u8, mf, "\\u0000zntc:runtime") != null);
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

    // 메인 번들의 worker specifier 가 build 결과 chunk filename 으로 치환되고
    // 두 번째 인자는 import.meta.url 그대로 (브라우저 ESM 기본).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".js\", import.meta.url)") != null);
    // 원본 specifier 는 사라짐
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./worker.ts") == null);

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
            try std.testing.expect(std.mem.startsWith(u8, a.contents, "(() => {"));
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

    // 두 worker URL 모두 chunk filename 으로 치환 (new URL 구조 보존).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-a-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-b-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./worker-a.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./worker-b.ts") == null);

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

    // 두 참조 모두 같은 chunk filename 으로 치환.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-") != null);
    // 원본 specifier 는 사라짐
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./worker.ts") == null);

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new SharedWorker(new URL(\"./shared-") != null);
    try std.testing.expect(result.asset_outputs != null);
}

test "Worker: platform node cjs emits cjs worker and file URL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\import { Worker } from 'node:worker_threads';
        \\const w = new Worker(new URL('./worker.ts', import.meta.url));
        \\w.postMessage(20);
    );
    try writeFile(tmp.dir, "worker.ts",
        \\import { parentPort } from 'node:worker_threads';
        \\parentPort.on('message', (value) => parentPort.postMessage(value + 22));
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-") != null);
    // import.meta.url polyfill 은 codegen 의 IMPORT_META_URL_NODE 와 일치 (drift 없음).
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".cjs\", require(\"url\").pathToFileURL(__filename).href)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./worker.ts") == null);

    const assets = result.asset_outputs orelse return error.TestUnexpectedResult;
    var found_worker = false;
    for (assets) |a| {
        if (std.mem.startsWith(u8, a.path, "worker-") and std.mem.endsWith(u8, a.path, ".cjs")) {
            found_worker = true;
            try std.testing.expect(std.mem.indexOf(u8, a.contents, "require(\"node:worker_threads\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, a.contents, "parentPort.on") != null);
        }
    }
    try std.testing.expect(found_worker);
}

test "Worker: same specifier in different modules resolves to distinct workers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("a");
    try tmp.dir.makeDir("b");
    try writeFile(tmp.dir, "entry.ts",
        \\import { run as runA } from "./a/index.ts";
        \\import { run as runB } from "./b/index.ts";
        \\runA(); runB();
    );
    try writeFile(tmp.dir, "a/index.ts",
        \\export function run() {
        \\  new Worker(new URL("./worker.ts", import.meta.url));
        \\}
    );
    try writeFile(tmp.dir, "a/worker.ts", "self.onmessage = (e) => self.postMessage('a');");
    try writeFile(tmp.dir, "b/index.ts",
        \\export function run() {
        \\  new Worker(new URL("./worker.ts", import.meta.url));
        \\}
    );
    try writeFile(tmp.dir, "b/worker.ts", "self.onmessage = (e) => self.postMessage('b');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // per-module map 이 같은 specifier 를 모듈마다 다른 chunk 로 매핑.
    // graph.worker_entries 에 a/worker.ts 와 b/worker.ts 두 절대 경로 등록 →
    // 두 worker chunk 가 별개로 emit, 각각 자신의 postMessage 본문 보유.
    const assets = result.asset_outputs orelse return error.TestUnexpectedResult;
    var saw_a = false;
    var saw_b = false;
    var worker_count: usize = 0;
    for (assets) |a| {
        if (!std.mem.startsWith(u8, a.path, "worker-")) continue;
        worker_count += 1;
        // codegen 의 quote_style 기본값은 double — single-quoted 입력도 double 로 normalize.
        if (std.mem.indexOf(u8, a.contents, "self.postMessage(\"a\")") != null) saw_a = true;
        if (std.mem.indexOf(u8, a.contents, "self.postMessage(\"b\")") != null) saw_b = true;
    }
    try std.testing.expectEqual(@as(usize, 2), worker_count);
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "Worker: non-worker new URL is preserved verbatim" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const api = new URL("/v1/users", "https://api.example.com");
        \\const file = new URL("./data.json", import.meta.url);
        \\console.log(api, file);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // worker_map 이 비어있으면 emitNew 의 fast-exit — 일반 new URL 호출은 그대로 emit.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(\"/v1/users\", \"https://api.example.com\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new URL(\"./data.json\", import.meta.url)") != null);
    try std.testing.expect(result.asset_outputs == null);
}

test "Worker: minified bundle preserves worker URL replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w = new Worker(new URL("./worker.ts", import.meta.url));
        \\w.postMessage("hi");
    );
    try writeFile(tmp.dir, "worker.ts", "self.onmessage = (e) => self.postMessage('pong');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_syntax = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // AST-based 치환이라 minify 후에도 정확. 이전 string 후처리는 minify 가 패턴을
    // 변형하면 깨질 위험 있었음 (회귀 방지 보호망).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import.meta.url)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "./worker.ts") == null);
}

test "Worker: platform browser cjs uses empty-string url polyfill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\const w = new Worker(new URL("./worker.ts", import.meta.url));
        \\w.postMessage("x");
    );
    try writeFile(tmp.dir, "worker.ts", "self.onmessage = (e) => self.postMessage('ok');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // browser+cjs/replace_import_meta: import.meta.url polyfill = "". codegen 의
    // writeImportMetaUrl 이 platform 분기 단일 source.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Worker(new URL(\"./worker-") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\", \"\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "pathToFileURL") == null);
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
        \\export const value = getValue();
        \\function getValue() { return 42; }
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
    // #3062 이후 synthetic JSX 우회 제거 + transformer 가 정식 import 노드 추가. 새
    // 방식에선 `_jsxDEV` 식별자가 source 의 canonical 로 rename 되어 substring
    // assertion 부적용. brittle substring 보다 더 robust 한 e2e DOM 검증으로 대체:
    //   - tests/e2e/tests/lib-scenario-e2e.test.ts 의 H1/H4/H5/H6 시나리오가
    //     preact JSX automatic 의 빌드 → 브라우저 실행 → DOM 검증까지 다룸.
    //     H4: 사용자 `_jsx` 식별자 충돌 (#3068 helper scope 격리)
    //     H5: 멀티 모듈 jsx-runtime 공유
    //     H6: barrel re-export JSX
    return error.SkipZigTest;
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
    // #3062 이후 substring assertion 부적용. e2e 대체:
    //   tests/e2e/tests/lib-scenario-e2e.test.ts 의 H5_preact_jsx_multi_module
    //   (CompA / CompB / entry 가 동시에 JSX 사용 + 브라우저 DOM 검증).
    return error.SkipZigTest;
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
    // #3062 이후 substring assertion 부적용. e2e 대체:
    //   tests/e2e/tests/lib-scenario-e2e.test.ts 의 H6_preact_jsx_re_export
    //   (barrel 파일 통과 후 Button 컴포넌트 → 브라우저 DOM 검증).
    return error.SkipZigTest;
}

test "JSX automatic: ESM-wrapped hoisted function can access _jsxDEV (scope test)" {
    // #3062 이후 substring assertion 부적용. e2e 대체:
    //   tests/e2e/tests/lib-scenario-e2e.test.ts 의 H1/H4/H5/H6 가 preact JSX
    //   automatic 의 빌드/렌더 정상성을 브라우저 동작까지 검증. 별도 ESM-wrapped
    //   require 소비 fixture 가 필요하면 후속 시나리오로 추가 가능.
    return error.SkipZigTest;
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

test "JSX automatic: non-ESM-wrapped module emits ESM external import" {
    // #1962: scope-hoisted 모듈은 chunk top 의 ESM `import { jsx as _jsx } from "react/jsx-runtime"`
    // 형태로 jsx-runtime binding 을 받는다 (esbuild/rolldown 동등). __esm 래퍼 없음.
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
    // __esm 이 아님 (일반 scope-hoisted)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm(") == null);
    // ESM external import 구문이 chunk top 에 prepend.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"react/jsx-runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_jsx") != null);
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
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = function greet() { return 'hello'; };
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

test "react_native preserve_symlinks: CJS-wrapped package ESM imports resolve from real pnpm package" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("apps/app/node_modules/@scope");
    try tmp.dir.makePath("apps/app/node_modules/react-native");
    try tmp.dir.makePath("node_modules/react-native");
    try writeFile(tmp.dir, "apps/app/node_modules/react-native/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "apps/app/node_modules/react-native/index.js", "exports.NativeModules = { CodePush: {} };");
    try writeFile(tmp.dir, "node_modules/react-native/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "node_modules/react-native/index.js", "exports.NativeModules = { CodePush: {} };");

    try tmp.dir.makePath("node_modules/.pnpm/pkg@1/node_modules/@scope/pkg");
    try tmp.dir.makePath("node_modules/.pnpm/pkg@1/node_modules/code-push/script");
    try tmp.dir.makePath("node_modules/.pnpm/pkg@1/node_modules/hoist-non-react-statics");
    try writeFile(tmp.dir, "node_modules/.pnpm/pkg@1/node_modules/@scope/pkg/package.json", "{\"main\":\"CodePush.js\"}");
    try writeFile(tmp.dir, "node_modules/.pnpm/pkg@1/node_modules/@scope/pkg/CodePush.js",
        \\import { AcquisitionManager as Sdk } from "code-push/script/acquisition-sdk";
        \\import hoistStatics from "hoist-non-react-statics";
        \\let NativeCodePush = require("react-native").NativeModules.CodePush;
        \\module.exports = { Sdk, hoistStatics, NativeCodePush };
    );
    try writeFile(tmp.dir, "node_modules/.pnpm/pkg@1/node_modules/code-push/package.json", "{\"main\":\"script/acquisition-sdk.js\"}");
    try writeFile(tmp.dir, "node_modules/.pnpm/pkg@1/node_modules/code-push/script/acquisition-sdk.js", "exports.AcquisitionManager = function AcquisitionManager() {};");
    try writeFile(tmp.dir, "node_modules/.pnpm/pkg@1/node_modules/hoist-non-react-statics/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "node_modules/.pnpm/pkg@1/node_modules/hoist-non-react-statics/index.js", "module.exports = function hoist() {};");

    tmp.dir.symLink(
        "../../../../node_modules/.pnpm/pkg@1/node_modules/@scope/pkg",
        "apps/app/node_modules/@scope/pkg",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try writeFile(tmp.dir, "apps/app/index.js",
        \\const CodePush = require("@scope/pkg");
        \\console.log(CodePush);
    );

    const entry = try absPath(&tmp, "apps/app/index.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .preserve_symlinks = true,
        .resolve_symlink_siblings = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"code-push/script/acquisition-sdk\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"hoist-non-react-statics\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NativeCodePush = require(\"react-native\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_code_push") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_hoist_non_react_statics") != null);
}

test "react_native preserve_symlinks: workspace symlink package resolves app logical dependencies first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("apps/app/node_modules/@scope");
    try tmp.dir.makePath("apps/app/node_modules/react-native-tcp-socket");
    try tmp.dir.makePath("packages/pkg/dist");
    try writeFile(tmp.dir, "apps/app/node_modules/react-native-tcp-socket/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "apps/app/node_modules/react-native-tcp-socket/index.js", "module.exports = { createConnection() {} };");
    try writeFile(tmp.dir, "packages/pkg/package.json", "{\"main\":\"dist/index.js\"}");
    try writeFile(tmp.dir, "packages/pkg/dist/index.js",
        \\import TcpSocket from "react-native-tcp-socket";
        \\export const socket = TcpSocket;
    );

    tmp.dir.symLink(
        "../../../../packages/pkg",
        "apps/app/node_modules/@scope/pkg",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try writeFile(tmp.dir, "apps/app/index.js",
        \\import { socket } from "@scope/pkg";
        \\console.log(socket);
    );

    const entry = try absPath(&tmp, "apps/app/index.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .preserve_symlinks = true,
        .resolve_symlink_siblings = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "react-native-tcp-socket") == null);
}

test "react_native preserve_symlinks: standard pnpm package symlink is bundled once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("apps/app/node_modules/@webview-bridge");
    try tmp.dir.makePath("node_modules/.pnpm/@webview-bridge+react-native@1/node_modules/@webview-bridge/react-native");
    try writeFile(tmp.dir, "node_modules/.pnpm/@webview-bridge+react-native@1/node_modules/@webview-bridge/react-native/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "node_modules/.pnpm/@webview-bridge+react-native@1/node_modules/@webview-bridge/react-native/index.js",
        \\const WebView = require("react-native-webview");
        \\exports.Bridge = WebView;
    );
    try writeFile(tmp.dir, "node_modules/.pnpm/react-native-webview@13/node_modules/react-native-webview/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "node_modules/.pnpm/react-native-webview@13/node_modules/react-native-webview/index.js",
        \\exports.marker = "RNC_WEBVIEW_SINGLETON_MARKER";
    );

    tmp.dir.symLink(
        "../../../node_modules/.pnpm/react-native-webview@13/node_modules/react-native-webview",
        "apps/app/node_modules/react-native-webview",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    tmp.dir.symLink(
        "../../../../node_modules/.pnpm/@webview-bridge+react-native@1/node_modules/@webview-bridge/react-native",
        "apps/app/node_modules/@webview-bridge/react-native",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    tmp.dir.symLink(
        "../../react-native-webview@13/node_modules/react-native-webview",
        "node_modules/.pnpm/@webview-bridge+react-native@1/node_modules/react-native-webview",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try writeFile(tmp.dir, "apps/app/index.js",
        \\const direct = require("react-native-webview");
        \\const bridge = require("@webview-bridge/react-native");
        \\console.log(direct.marker, bridge.Bridge.marker);
    );

    const entry = try absPath(&tmp, "apps/app/index.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .metafile = true,
        .preserve_symlinks = true,
        .resolve_symlink_siblings = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    var marker_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "RNC_WEBVIEW_SINGLETON_MARKER")) |pos| {
        marker_count += 1;
        search_from = pos + "RNC_WEBVIEW_SINGLETON_MARKER".len;
    }
    try std.testing.expectEqual(@as(usize, 1), marker_count);
    const metafile = result.metafile_json orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, metafile, "node_modules/.pnpm/react-native-webview@13/node_modules/react-native-webview/index.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, metafile, "apps/app/node_modules/react-native-webview/index.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, metafile, "@webview-bridge+react-native@1/node_modules/react-native-webview/index.js") == null);
}

test "preserve_symlinks: alias to pnpm symlink package root bundles package entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("apps/app/node_modules");
    try writeFile(tmp.dir, "node_modules/.pnpm/react@1/node_modules/react/package.json", "{\"main\":\"index.js\"}");
    try writeFile(tmp.dir, "node_modules/.pnpm/react@1/node_modules/react/index.js", "exports.version = 'test';\n");
    tmp.dir.symLink(
        "../../../node_modules/.pnpm/react@1/node_modules/react",
        "apps/app/node_modules/react",
        .{ .is_directory = true },
    ) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    try writeFile(tmp.dir, "apps/app/index.js",
        \\const React = require("react");
        \\console.log(React.version);
    );

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const entry = try absPath(&tmp, "apps/app/index.js");
    defer std.testing.allocator.free(entry);
    const react_root = try std.fs.path.join(std.testing.allocator, &.{ root, "apps/app/node_modules/react" });
    defer std.testing.allocator.free(react_root);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .format = .iife,
        .tree_shaking = false,
        .metafile = true,
        .preserve_symlinks = true,
        .alias = &.{.{ .from = "react", .to = react_root }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const metafile = result.metafile_json orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, metafile, "apps/app/node_modules/react/index.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, metafile, "apps/app/node_modules/react\"") == null);
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
    const VDK = @import("../../parser/ast.zig").VariableDeclarationKind;
    // let → var
    try std.testing.expectEqual(VDK.@"var", block_scoping.lowerKind(.let));
    // const → var
    try std.testing.expectEqual(VDK.@"var", block_scoping.lowerKind(.@"const"));
    // var → var 그대로
    try std.testing.expectEqual(VDK.@"var", block_scoping.lowerKind(.@"var"));
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

test "RN preset: arrow worklet params → __closure에서 제외 (#1283 Reanimated filter.ts 케이스)" {
    // Reanimated worklet arrow `(value, context) => { 'worklet'; ... }`에서 value/context는
    // 파라미터이므로 __closure에 포함되면 안 됨 (Hermes ReferenceError 유발).
    // ES5 타겟은 arrow→function 선변환으로 우연히 통과했지만, RN preset은 arrow 보존이라
    // parser 레벨에서 arrow params를 formal_parameters로 정규화해야 worklet plugin이 올바르게 인식.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\var ext = 1;
        \\const pf = (value, context) => {
        \\  'worklet';
        \\  return ext + value + context;
        \\};
        \\console.log(pf);
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .worklet_transform = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ext: ext") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value: value") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "context: context") == null);
    // generateCode의 __initData.code 문자열에 params가 유지돼야 한다 (Hermes runtime이 arg 전달용).
    // 함수 이름은 파일 경로 기반이라 테스트 환경마다 다르므로 `(value,context)`만 확인.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(value,context){") != null);
}

test "RN preset: #1302 for-of destructuring + const→var는 void 0 init 추가 안 함" {
    // for-of/for-in의 left는 매 반복 iter value를 binding하므로 init 불필요.
    // block_scoping이 무조건 `void 0` init 추가하면 `{x} = void 0` invalid statement 생성.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\const updates = [{id:1, instance:2, color:3}];
        \\for (const { id, instance, color } of updates) {
        \\  console.log(id);
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
    // 잘못된 `{...} = void 0;` statement가 emit되지 않아야 함
    // (RN preset에서 destructuring/for-of 자체도 다운레벨되므로 패턴이 더 변환되지만,
    // 핵심 회귀 조건은 destructuring + no-init declarator에 void 0가 안 붙는 것)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "} = void 0;") == null);
}

test "RN preset: for-of loop closure preserves method this" {
    // 루프 body 를 _loop 함수로 추출하더라도 원래 메서드의 `this` 의미를 보존해야 한다.
    // RN DebuggingOverlayRegistry 의 private method call 이 이 경로에서 깨졌다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\const callbacks = [];
        \\class Registry {
        \\  #find(instance) { return instance; }
        \\  draw(updates) {
        \\    const out = [];
        \\    for (const { id, instance, color } of updates) {
        \\      const parent = this.#find(instance);
        \\      callbacks.push(function() { return id + color; });
        \\      out.push(parent);
        \\    }
        \\    return out;
        \\  }
        \\}
        \\console.log(new Registry().draw([{ id: 1, instance: 2, color: 3 }]), callbacks[0]());
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_loop.call(this") != null);
}

test "RN preset: #1299 let/const → var 다운레벨 (Hermes block scoping)" {
    // `for (let q = 0, ...)` 같은 패턴이 object literal 평가를 깨뜨려 후속 prop 누락.
    // arrow → function 변환만으로 회피되지 않음. Rolldown도 block-scoping 변환.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\const obj = {
        \\  flushQueue: function() {
        \\    for (let q = 0, l = 10; q < l; q++) { /* */ }
        \\    const x = 1;
        \\  },
        \\  createNode(tag) { return tag; },
        \\};
        \\console.log(Object.keys(obj));
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
    // let/const 키워드가 출력에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for (let") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x") == null);
    // var로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for (var") != null);
}

test "RN preset: #1299 arrow → function 다운레벨 (Hermes object literal arrow ternary 버그 회피)" {
    // 이슈 #1299: 큰 arrow function ternary가 object property value 위치에 있을 때
    // Hermes 런타임이 후속 prop을 누락. Rolldown + @react-native/babel-preset도 사용자 arrow를 사실상 모두
    // function으로 변환하므로 동일 정책.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\const obj = {
        \\  flushQueue: (true ? () => { return 1; } : () => { return 2; }),
        \\  createNode(tag) { return tag; },
        \\};
        \\console.log(Object.keys(obj));
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
    // arrow 구문 (` => `)이 출력에 없어야 함 (모두 function으로 변환)
    try std.testing.expect(std.mem.indexOf(u8, result.output, " => ") == null);
}

test "RN preset: async/await도 ES5 매트릭스로 다운레벨 (보수적 정책)" {
    // RN preset은 사실상 ES5 매트릭스 — async도 state machine으로 변환.
    // #1306에서 sent() throw-check 수정 후 rejected Promise 전파 정상 동작.
    // 네이티브 async 보존이 필요하면 fromHermesPreset()의 async_await만 false로 토글.
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
    // async function이 더 이상 native 형태로 남지 않음 (state machine으로 변환)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function f") == null);
}

// Regression: JSX automatic runtime 의 `<Comp {...props} key={x} />` 패턴은 jsxDEV/jsx
// 의 signature 로 표현할 수 없어 jsx_lowering 이 `_createElement(tag, {...props, key: x})`
// fallback 을 emit. single-file transpile 은 `import { createElement as _createElement } from "react";`
// 를 prepend 하지만 bundle mode 는 jsx_import_info 를 무시해 `_createElement` 가 free variable
// 로 남는다. expo-router 의 `useScreens.js` 등 컴파일된 패키지에서 이 패턴이 흔해 RN 부팅 시
// ReferenceError.
test "JSX automatic: _createElement import injected when key-after-spread used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\export function App(props) {
        \\  return <div {...props} key={props.id} />;
        \\}
    );
    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        .external = &.{ "react/jsx-dev-runtime", "react" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // key-after-spread fallback 이 실제로 트리거되어야 — `_createElement(` 호출 존재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_createElement(") != null);
    // #1962 ESM external: `import { createElement as _createElement } from "react";` 형태로 주입.
    // free variable 이면 안 되므로 react import 와 _createElement 식별자가 모두 출력에 존재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"react\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement as _createElement") != null);
}

// Regression: expo-router 의 `useScreens.js` 처럼 .js 확장자 + JSX 인 케이스.
// 실제 expo-router 빌드 산출물의 routeToScreen() 형태를 그대로 재현.
// .tsx 가 아닌 .js 에서도 동일 fix 가 동작해야 함 (JSX 활성은 확장자가 아니라 ast.has_jsx).
test "JSX automatic: _createElement injected for .js source (expo-router useScreens shape)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\const primitives = { Screen: function() { return null; } };
        \\export function routeToScreen(route, opts = {}) {
        \\  const { options, getId, ...props } = opts;
        \\  return (<primitives.Screen {...props} name={route.route} key={route.route} getId={getId} options={options}/>);
        \\}
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic_dev,
        // RN 프리셋과 동일하게 .js 에서 JSX 파싱 활성화 — bungae 가 react-native platform 으로
        // 호출 시 자동으로 true. 이게 없으면 .js 의 JSX 가 syntax error.
        .jsx_in_js = true,
        .external = &.{ "react/jsx-dev-runtime", "react" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_createElement(") != null);
    // #1962 ESM external: `import { createElement as _createElement } from "react";` 형태.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"react\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement as _createElement") != null);
}

// ============================================================================
// entry_error_guard — Metro guardedLoadModule 호환 (top-level require throw 차단)
// ============================================================================

// iOS 26.4+ 의 native immutable global (`Location` 등) 과 polyfill 충돌이 흔함:
// expo-metro-runtime 이 `Object.defineProperty(global, 'Location', ...)` 시도 →
// configurable=false 라 `TypeError: property is not configurable` throw → entry
// 평가 자체 throw → "runtime not ready" 부팅 실패. Metro 는 `guardedLoadModule`
// 가 throw 를 `ErrorUtils.reportFatalError` 로 swallow 해 부팅 진행. ZNTC 도 동일
// mechanism 도입 — entry trigger 호출을 try/catch + ErrorUtils wrap.
// ============================================================================
// Option B 엣지 케이스 — Metro guardedLoadModule 100% 동등 mechanism
// ============================================================================
//
// 검증 invariant:
// 1. helper 가 prologue 에 1번만 emit (중복 방지)
// 2. helper 의 inGuard pattern 보존 (Metro 동등) — nested 호출은 throw propagate
// 3. runBeforeMain unroll — runBeforeMainModule은 entry trigger 앞의 separate
//    top-level statement 로 emit
// 4. entry dependency chain 과 비-entry 모듈 chain 호출은 factory body 안에 남아
//    nested throw propagation 보존
// 5. ErrorUtils 정의 환경 / 미정의 환경 fallback 정확
// 6. side-effect / re-export / CJS / mixed / TLA edge case 모두 안전
// 7. minify 출력에서도 동일 의미

fn buildRnGuarded(allocator: std.mem.Allocator, entry: []const u8) !Bundler {
    return Bundler.init(allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
    });
}

const expo_polyfill_pattern = "^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$";

fn buildRnGuardedWithSilentPatterns(allocator: std.mem.Allocator, entry: []const u8, patterns: []const []const u8) !Bundler {
    return Bundler.init(allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
        .silent_console_error_patterns = patterns,
    });
}

test "entry_error_guard #1: 옵션 활성 시 prologue 에 Metro guard helper emit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // helper 정의 + Metro guardedLoadModule semantics:
    // outer guard + ErrorUtils.reportFatalError, ErrorUtils 없으면 fallback rethrow.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __zntc_guarded") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_in_guard") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guard_global.ErrorUtils.reportFatalError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return fn();") != null);
}

test "entry_error_guard #2: 옵션 비활성 시 helper / wrap 모두 없음 (회귀 방지)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __zntc_guarded") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_in_guard") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ErrorUtils.reportFatalError") == null);
}

test "entry_error_guard #3: helper 정의 1번만 emit (중복 방지)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const a = 1;\n");
    try writeFile(tmp.dir, "b.js", "export const b = 2;\n");
    try writeFile(tmp.dir, "entry.js",
        \\import { a } from './a.js';
        \\import { b } from './b.js';
        \\export const sum = a + b;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const helper_count = std.mem.count(u8, result.output, "function __zntc_guarded");
    try std.testing.expectEqual(@as(usize, 1), helper_count);
}

test "entry_error_guard #4: 단순 entry — chain unroll 없이 entry trigger 만 wrap" {
    // entry 가 chain 없이 자체 코드만 — chain unroll 대상 없음
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const v = 42;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 적어도 entry trigger 1번 wrap
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(") != null);
}

test "entry_error_guard #5: 다중 chain entry — import init 은 entry guard 안에 유지" {
    // Metro는 entry `__r(entry)` 하나만 outer guard로 감싸고, entry import chain은
    // factory 내부 nested require로 실행한다. dependency throw가 entry 평가를 중단해야
    // 하므로 import init을 top-level 개별 guard로 풀면 안 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "globalThis.__guardA = 1; export const a = globalThis.__guardA;\n");
    try writeFile(tmp.dir, "b.js", "globalThis.__guardB = 2; export const b = globalThis.__guardB;\n");
    try writeFile(tmp.dir, "c.js", "globalThis.__guardC = 3; export const c = globalThis.__guardC;\n");
    try writeFile(tmp.dir, "entry.js",
        \\import { a } from './a.js';
        \\import { b } from './b.js';
        \\import { c } from './c.js';
        \\export const sum = a + b + c;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const marker = "//#endregion\n";
    const top_start = (std.mem.lastIndexOf(u8, result.output, marker) orelse 0) + marker.len;
    const top_level = result.output[top_start..];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, top_level, "__zntc_guarded("));
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_a") == null);
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_b") == null);
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_c") == null);
}

test "entry_error_guard #5b: runBeforeMain 을 entry 앞에 분리하고 entry import 는 중첩 유지" {
    // 재현 최소 케이스: runBeforeMain이 ErrorUtils를 설치한 뒤 entry dependency가 throw.
    // Metro에서는 entry outer guard가 그 throw를 report하고 entry factory를 중단하므로
    // 뒤 import/entry body가 실행되지 않는다. zntc가 entry import를 top-level 개별 guard로
    // unroll하면 throw가 swallow되어 뒤 import가 계속 실행된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "setup.js", "globalThis.ErrorUtils = { reportFatalError(e) { globalThis.reported = e.message; } };\n");
    try writeFile(tmp.dir, "boom.js", "throw new Error('boom');\n");
    try writeFile(tmp.dir, "after.js", "globalThis.afterRan = true;\n");
    try writeFile(tmp.dir, "entry.js",
        \\import './boom.js';
        \\import './after.js';
        \\globalThis.entryRan = true;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const setup = try absPath(&tmp, "setup.js");
    defer std.testing.allocator.free(setup);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
        .run_before_main = &.{setup},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const marker = "//#endregion\n";
    const top_start = (std.mem.lastIndexOf(u8, result.output, marker) orelse 0) + marker.len;
    const top_level = result.output[top_start..];
    const setup_call = "__zntc_guarded(init_setup);";
    const setup_call_idx = std.mem.indexOf(u8, result.output, setup_call) orelse return error.SetupCallMissing;
    const entry_top_idx = std.mem.indexOf(u8, top_level, "init_entry") orelse return error.EntryTopLevelCallMissing;
    const entry_abs_idx = top_start + entry_top_idx;
    try std.testing.expect(setup_call_idx < entry_abs_idx);
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_boom") == null);
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_after") == null);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(function(){return init_boom();});") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(function(){return init_after();});") != null);
}

test "entry_error_guard #5c: runBeforeMain 은 dependency closure 정의 뒤 entry 앞에서 실행" {
    // Metro 는 모든 factory 를 define 한 뒤 append script 에서 runBeforeMainModule 을
    // require 한다. RN 0.85 InitializeCore 는 평가 중 뒤쪽 facade(RendererProxy 같은
    // re-export-only 모듈)를 require 할 수 있으므로, zntc 도 runBeforeMain 이 당겨 쓸
    // dependency closure 를 모두 등록한 뒤 entry body 보다 먼저 실행해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "setup.js",
        \\import { value } from './facade.js';
        \\globalThis.setupValue = value;
    );
    try writeFile(tmp.dir, "facade.js", "export * from './impl.js';\n");
    try writeFile(tmp.dir, "impl.js", "export const value = 1;\n");
    try writeFile(tmp.dir, "entry.js",
        \\globalThis.entryRan = true;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const setup = try absPath(&tmp, "setup.js");
    defer std.testing.allocator.free(setup);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
        .run_before_main = &.{setup},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const setup_call_idx = std.mem.indexOf(u8, result.output, "__zntc_guarded(init_setup);") orelse return error.SetupCallMissing;
    const facade_region_idx = std.mem.indexOf(u8, result.output, "//#region facade.js") orelse return error.FacadeModuleMissing;
    const entry_body_idx = std.mem.indexOf(u8, result.output, "entryRan") orelse return error.EntryBodyMissing;
    try std.testing.expect(facade_region_idx < setup_call_idx);
    try std.testing.expect(setup_call_idx < entry_body_idx);
}

test "react_native dev auto InitializeCore: preserve_symlinks logical runBeforeMain 중복 주입 방지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("app/node_modules");
    try writeFile(tmp.dir, ".pnpm/react-native@1/node_modules/react-native/Libraries/Core/InitializeCore.js",
        \\globalThis.initCoreCount = (globalThis.initCoreCount || 0) + 1;
    );
    tmp.dir.symLink("../../.pnpm/react-native@1/node_modules/react-native", "app/node_modules/react-native", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    try writeFile(tmp.dir, "app/index.js", "globalThis.entryRan = true;\n");

    const entry = try absPath(&tmp, "app/index.js");
    defer std.testing.allocator.free(entry);
    const init_core = try absPath(&tmp, "app/node_modules/react-native/Libraries/Core/InitializeCore.js");
    defer std.testing.allocator.free(init_core);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .dev_mode = true,
        .react_refresh = true,
        .preserve_symlinks = true,
        .run_before_main = &.{init_core},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "app/node_modules/react-native/Libraries/Core/InitializeCore.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".pnpm/react-native@1/node_modules/react-native/Libraries/Core/InitializeCore.js") == null);
}

test "entry_error_guard #5d: scope-hoisted named import from ESM wrap keeps live binding rename" {
    // RN Release 재현: sideEffects 패턴으로 target(utils)은 __esm wrap 되고,
    // consumer(pressable)는 scope-hoisted 된다. import binding rename 이 self
    // canonical rename 으로 덮이면 `isTestEnv$N()` 같은 미정의 로컬 호출이 남는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"pressable.js","sideEffects":["./utils.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/utils.js",
        \\export function isTestEnv() { return false; }
        \\export const INT32_MAX = 2147483647;
    );
    try writeFile(tmp.dir, "node_modules/pkg/pressable.js",
        \\import { INT32_MAX, isTestEnv } from './utils.js';
        \\export const IS_TEST_ENV = isTestEnv();
        \\export const MAX = INT32_MAX;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { IS_TEST_ENV, MAX } from 'pkg';
        \\globalThis.result = [IS_TEST_ENV, MAX];
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm({") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "IS_TEST_ENV = isTestEnv()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "isTestEnv$") == null);
}

test "entry_error_guard #6: side-effect import — wrap 적용 + 평가 시점 보존" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "side.js",
        \\globalThis.__sideMarker = 42;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import './side.js';
        \\export const ok = true;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // side.js 본문 (sideMarker 할당) 이 bundle 에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__sideMarker") != null);
    // entry trigger 가 wrap
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(") != null);
}

test "entry_error_guard #7: re-export entry — chain unroll 안 깨짐" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\export const fn = () => 42;
        \\export const VAL = 1;
    );
    try writeFile(tmp.dir, "entry.js",
        \\export * from './lib.js';
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // re-export source 가 bundle 에
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VAL") != null);
}

test "entry_error_guard #8: CJS entry — require_X() wrap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\module.exports = { x: 1 };
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(") != null);
}

test "entry_error_guard #9: mixed CJS + ESM dependencies — 모두 wrap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "esm.js", "export const e = 1;\n");
    try writeFile(tmp.dir, "cjs.js", "module.exports = { c: 2 };\n");
    try writeFile(tmp.dir, "entry.js",
        \\import { e } from './esm.js';
        \\const cjs = require('./cjs.js');
        \\export const sum = e + cjs.c;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈 평가 위치 모두 wrap
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(") != null);
}

test "entry_error_guard #10: Metro inGuard + ErrorUtils fallback rethrow semantics" {
    // Metro 는 ErrorUtils 가 있을 때만 outermost 호출을 catch/report 한다.
    // ErrorUtils 미정의 구간은 unguarded 로 실행해야 InitializeCore 실패를 숨기지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const v = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "if (!__zntc_in_guard && __zntc_guard_global && __zntc_guard_global.ErrorUtils)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_in_guard = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_in_guard = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return fn();") != null);
}

test "entry_error_guard #11: entry 안의 var/function 정의 + chain 혼재" {
    // chain unroll 후에도 entry 의 자체 코드 (var/function) 가 평가되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js", "export const l = 10;\n");
    try writeFile(tmp.dir, "entry.js",
        \\import { l } from './lib.js';
        \\const x = 1;
        \\function f() { return l + x; }
        \\export const result = f();
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry 의 자체 코드 (function f) bundle 에
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function f") != null or
        std.mem.indexOf(u8, result.output, "f = function") != null);
}

test "entry_error_guard #12: TLA entry — wrap 안 함 (await 보존)" {
    // top-level await 인 entry 는 await 가 lambda 안에 못 들어가서 wrap 안 함.
    // appendGuardedModuleCall 의 `if (tla) appendModuleCall(); return;` 분기.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\const v = await Promise.resolve(42);
        \\export const result = v;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser, // RN 은 TLA 미지원 — browser 로
        .format = .esm,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // await 보존 — bundle 어딘가에 await 키워드 살아있어야
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await ") != null);
}

test "entry_error_guard #13: minify_whitespace — minified helper 형태 정상" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minified 형태도 helper 정의 + Metro ErrorUtils guard 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function $zg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$zg(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$zgG.ErrorUtils.reportFatalError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return fn()") != null);
}

test "entry_error_guard #14: 비-entry 모듈의 chain 도 wrap (preamble + side-effect)" {
    // entry 만 unroll 이지만, 비-entry 모듈 안의 chain 호출도 `__zntc_guarded(...)`
    // 패턴으로 emit (linker preamble + esm_wrap side-effect 양쪽).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "leaf.js", "export const v = getV();\nfunction getV() { return 1; }\n");
    try writeFile(tmp.dir, "mid.js",
        \\import { v } from './leaf.js';
        \\export const m = v + 1;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { m } from './mid.js';
        \\export const r = m;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 여러 chain 위치에 wrap
    const guarded_calls = std.mem.count(u8, result.output, "__zntc_guarded(");
    try std.testing.expect(guarded_calls >= 2);
}

test "entry_error_guard #15: entry import chain 은 entry init body 안에 남김" {
    // Metro 동등성 검증: entry 모듈의 init body 안에 import init 호출이 남아야 한다.
    // bundle 끝 entry trigger 영역에는 entry 자체 호출만 있어야 dependency throw가
    // 같은 outer guard 아래에서 전파된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.js", "export const d = 1;\n");
    try writeFile(tmp.dir, "entry.js",
        \\import { d } from './dep.js';
        \\export const r = d;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const marker = "//#endregion\n";
    const top_start = (std.mem.lastIndexOf(u8, result.output, marker) orelse 0) + marker.len;
    const top_level = result.output[top_start..];
    try std.testing.expect(std.mem.indexOf(u8, top_level, "init_dep") == null);
}

test "entry_error_guard #16: GUARD_LAMBDA 매크로 형식 — esm_wrap / metadata 두 사이트 일관" {
    // /simplify 후 hoist 한 GUARD_LAMBDA_OPEN/CLOSE const 가 두 사이트에서 동일한 wrap
    // shape 으로 emit 되는지 검증. 한 사이트 emit 형식이 drift 하면 helper signature
    // 가 깨짐 (`__zntc_guarded(function(){return X;})` 만 helper 가 받음).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "leaf.js", "export const v = getV();\nfunction getV() { return 1; }\n");
    try writeFile(tmp.dir, "entry.js",
        \\import './leaf.js';
        \\import { v } from './leaf.js';
        \\export const r = v;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 wrap 호출은 정확히 `__zntc_guarded(function(){return ` 으로 시작한다.
    // statement guard 는 `;});`, expression guard 는 `}),` 로 닫힌다.
    // expression guard 에 statement terminator 가 섞이면 `(...;});, value)` 문법 오류가 된다.
    const open_count = std.mem.count(u8, result.output, "__zntc_guarded(function(){return ");
    const statement_close_count = std.mem.count(u8, result.output, ";});");
    const expression_close_count = std.mem.count(u8, result.output, "}),");
    try std.testing.expect(open_count >= 2);
    // close 는 wrap 외 다른 곳 (ESM closure 등) 에서도 나올 수 있어 >= 만 검증.
    try std.testing.expect(statement_close_count + expression_close_count >= open_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".fn();});\n,") == null);
}

test "entry_error_guard #17: silent_console_error_patterns 주입 시 setter intercept emit" {
    // 패턴 배열 주입 시 prologue 에 `Object.defineProperty(console, "error", { set })` 등장 +
    // IGNORE regex literal 포함. RN `setUpDeveloperTools` 가 console.error 를 다시 wrap 해도
    // 우리 setter 가 그 위에 wrap 을 다시 씌워 outermost 유지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    const patterns = [_][]const u8{expo_polyfill_pattern};
    var b = try buildRnGuardedWithSilentPatterns(std.testing.allocator, entry, &patterns);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // IGNORE regex literal — 주입한 패턴 그대로 emit.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Failed to set polyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "is not configurable") != null);
    // setter intercept — Object.defineProperty(console, "error", { set ... })
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Object.defineProperty(console, \"error\"") != null);
    // get/set descriptor 모두 존재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get: function() { return current; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "set: function(fn)") != null);
    // configurable: true — RN 등 후속 코드가 다시 set 할 수 있게.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "configurable: true") != null);
}

test "entry_error_guard #17b: silent_console_error_patterns 비어있으면 setter intercept emit X" {
    // 패턴 비어있으면 vanilla RN 빌드처럼 console wrap 자체 emit 안 됨 → dead code 0.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry); // patterns 비어있음
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // setter intercept 없음.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Object.defineProperty(console, \"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Failed to set polyfill") == null);
    // 단 __zntc_guarded helper 는 entry_error_guard 활성이라 emit.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __zntc_guarded") != null);
}

test "entry_error_guard #18: silent swallow/debug toggle 제거 — Metro ErrorUtils 보고만 사용" {
    // `__zntc_guarded` 는 Metro 와 동일하게 ErrorUtils 가 있으면 reportFatalError,
    // 없으면 rethrow. 별도 debug toggle 로 예외를 삼키지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = try buildRnGuarded(std.testing.allocator, entry);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__ZNTC_DEBUG_GUARD") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[zntc:guard]") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.warn") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guard_global.ErrorUtils.reportFatalError") != null);
}

test "entry_error_guard #19: dev_mode + entry import chain — __zntc_modules[\"...\"].fn() 도 중첩 wrap" {
    // dev_mode 에서는 init 호출이 `__zntc_modules["id"].fn()` 형식이다. entry import
    // chain도 entry factory 내부에 남기되 동일한 guard lambda 형식을 유지해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.js", "export const d = getD();\nfunction getD() { return 1; }\n");
    try writeFile(tmp.dir, "entry.js",
        \\import { d } from './dep.js';
        \\globalThis.__zntcGuardDevValue = d;
        \\export const r = d;
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .entry_error_guard = true,
        .dev_mode = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // dev_mode 형식 + nested wrap 둘 다 존재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_guarded(function(){return __zntc_modules[") != null);
    const marker = "//#endregion\n";
    const top_start = (std.mem.lastIndexOf(u8, result.output, marker) orelse 0) + marker.len;
    const top_level = result.output[top_start..];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, top_level, "__zntc_guarded("));
    try std.testing.expect(std.mem.indexOf(u8, top_level, "dep.js") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".fn();});\n,") == null);
}

test "entry_error_guard #20: silent_console_error_patterns 정확도 — 실제 expo 메시지 형식과 매치" {
    // 주입한 expo polyfill 패턴이 console intercept emit 결과에 정확한 regex literal 로 들어있어야 함.
    // expo 메시지 형식 (Location, TextEncoderStream, TextDecoderStream) 의 name 부분이 `\w+` 매칭.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    const patterns = [_][]const u8{expo_polyfill_pattern};
    var b = try buildRnGuardedWithSilentPatterns(std.testing.allocator, entry, &patterns);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 주입한 패턴이 정확히 regex literal 로 emit (escape 보존).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$/") != null);

    // 의미 검증 — sample 메시지 들의 name 부분이 모두 ASCII letter (`\w+` 매치 가능).
    const samples = [_][]const u8{
        "Failed to set polyfill. Location is not configurable.",
        "Failed to set polyfill. TextEncoderStream is not configurable.",
        "Failed to set polyfill. TextDecoderStream is not configurable.",
    };
    for (samples) |sample| {
        const name_start = std.mem.indexOf(u8, sample, "polyfill. ").? + "polyfill. ".len;
        const name_end = std.mem.indexOf(u8, sample[name_start..], " is").? + name_start;
        const name = sample[name_start..name_end];
        for (name) |c| {
            try std.testing.expect((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z'));
        }
    }
}

test "entry_error_guard #21: silent_console_error_patterns 다중 패턴 — 모두 IGNORE array 에 emit" {
    // 사용자가 여러 RegExp 주입 시 [...,...] 배열로 emit. 각 패턴 독립 test.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "export const x = 1;\n");
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    const patterns = [_][]const u8{
        expo_polyfill_pattern,
        "^Some other warning$",
    };
    var b = try buildRnGuardedWithSilentPatterns(std.testing.allocator, entry, &patterns);
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/^Failed to set polyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/^Some other warning$/") != null);
    // 배열 loop 으로 검사 (단일 regex .test 가 아니라 IGNORE.length loop).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for (var i = 0; i < IGNORE.length") != null);
}

test "react_native re-export getters defer ESM source initialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { capture } from './browser-index';
        \\globalThis.__zntcReExportLazyResult = capture();
    );
    try writeFile(tmp.dir, "browser-index.js",
        \\export { capture } from './core';
        \\export { feedbackAsyncIntegration } from './feedbackAsync';
    );
    try writeFile(tmp.dir, "core.js",
        \\export function capture() { return 'captured'; }
    );
    try writeFile(tmp.dir, "feedbackAsync.js",
        \\import { buildFeedbackIntegration } from './feedback';
        \\export const feedbackAsyncIntegration = buildFeedbackIntegration();
    );
    try writeFile(tmp.dir, "feedback.js",
        \\const DOCUMENT = globalThis.WINDOW.document;
        \\export function buildFeedbackIntegration() { return DOCUMENT; }
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const feedback_async = try absPath(&tmp, "feedbackAsync.js");
    defer std.testing.allocator.free(feedback_async);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .dev_mode = true,
        .entry_error_guard = true,
        .tree_shaking = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const eager_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}__zntc_modules[\"{s}\"].fn();}});\n",
        .{ rt.GUARD_LAMBDA_OPEN, feedback_async },
    );
    defer std.testing.allocator.free(eager_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, eager_init) == null);

    const lazy_getter = try std.fmt.allocPrint(
        std.testing.allocator,
        "({s}__zntc_modules[\"{s}\"].fn()}}), exports_",
        .{ rt.GUARD_LAMBDA_OPEN, feedback_async },
    );
    defer std.testing.allocator.free(lazy_getter);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_getter) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "feedbackAsyncIntegration") != null);
}

test "react_native inlineRequires: defer function-only ESM imports across selector cycles" {
    // Payhere mobile-seller 축소 재현:
    // seller selector 가 함수 안에서만 seller module state 를 읽는데, 그 import 를
    // eager init 하면 sellerModule -> sagas -> local -> sellerSelectors 순환이 먼저 열려
    // local 의 top-level createSelector 가 아직 할당 전인 getMode 를 받는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { getMode, readInitial } from './sellerSelectors';
        \\globalThis.__zntcInlineRequiresResult = [getMode(), readInitial()];
    );
    try writeFile(tmp.dir, "reselect.js",
        \\export function createSelector(inputs, result) {
        \\  if (inputs.some((fn) => typeof fn !== 'function')) {
        \\    throw new Error('bad selector');
        \\  }
        \\  return function selector() {
        \\    return result(...inputs.map((fn) => fn()));
        \\  };
        \\}
    );
    try writeFile(tmp.dir, "local.js",
        \\import { createSelector } from './reselect';
        \\import { getMode } from './sellerSelectors';
        \\export const storage = () => true;
        \\export const select = createSelector(
        \\  [getMode, storage],
        \\  (mode, visible) => mode && visible,
        \\);
    );
    try writeFile(tmp.dir, "sellerSelectors/index.js",
        \\export * from './seller';
    );
    try writeFile(tmp.dir, "sellerSelectors/seller.js",
        \\import { sellerInitialState } from '../sellerModule';
        \\export const getMode = () => true;
        \\export function readInitial() {
        \\  return sellerInitialState.ready ? 'READY_MARKER' : 'EMPTY_MARKER';
        \\}
    );
    try writeFile(tmp.dir, "sellerModule/index.js",
        \\export { sellerInitialState } from './module';
        \\export { watchers } from './sagas';
    );
    try writeFile(tmp.dir, "sellerModule/module.js",
        \\export const sellerInitialState = { ready: true };
    );
    try writeFile(tmp.dir, "sellerModule/sagas.js",
        \\import { select } from '../local';
        \\export const watchers = [select];
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sellerInitialState.ready") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sellerInitialState).ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "READY_MARKER") != null);

    var dev_b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer dev_b.deinit();
    const dev_result = try dev_b.bundle();
    defer dev_result.deinit(std.testing.allocator);

    try std.testing.expect(!dev_result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, dev_result.output, "__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, dev_result.output, "sellerInitialState.ready") == null);
    try std.testing.expect(std.mem.indexOf(u8, dev_result.output, "sellerInitialState).ready") != null);
}

test "react_native inlineRequires: defer top-level ESM value imports to use site" {
    // Metro inlineRequires 는 named import 의 require() 를 모듈 선두로 올리지 않고
    // 실제 값 참조 지점에 둔다. Payhere mobile-seller 의 selector/navigator cycle 에서
    // zntc 가 import init 을 먼저 실행하면 Metro 보다 이른 시점에 순환 모듈이 열려
    // reselect input selector 가 undefined 로 평가된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { select } from './local';
        \\globalThis.__zntcTopLevelInlineRequiresResult = select();
    );
    try writeFile(tmp.dir, "reselect.js",
        \\export function createSelector(inputs, result) {
        \\  if (inputs.some((fn) => typeof fn !== 'function')) {
        \\    throw new Error('bad selector');
        \\  }
        \\  return function selector() {
        \\    return result(...inputs.map((fn) => fn()));
        \\  };
        \\}
    );
    try writeFile(tmp.dir, "local.js",
        \\import { createSelector } from './reselect';
        \\import { getRemoteValue } from './remote';
        \\export const getLocalValue = () => 'local';
        \\export const select = createSelector([getRemoteValue], (value) => value);
    );
    try writeFile(tmp.dir, "remote.js",
        \\import { createSelector } from './reselect';
        \\import { getLocalValue } from './local';
        \\export const getRemoteBase = () => 'remote';
        \\export const getRemoteValue = createSelector([getLocalValue], (value) => value);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const remote = try absPath(&tmp, "remote.js");
    defer std.testing.allocator.free(remote);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const eager_remote_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn();}});",
        .{remote},
    );
    defer std.testing.allocator.free(eager_remote_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, eager_remote_init) == null);

    const lazy_remote_value = try std.fmt.allocPrint(
        std.testing.allocator,
        "(__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}),",
        .{remote},
    );
    defer std.testing.allocator.free(lazy_remote_value);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_remote_value) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".fn();});\n,") == null);
}

test "react_native inlineRequires: strict order still defers named CJS imports" {
    // Metro inlineRequires 는 CJS named import 도 값 사용 지점에서 require 한다.
    // strictExecutionOrder 가 켜져도 이 named import 를 선행 실행하면 RN app 초기
    // render 전에 CJS barrel 의 DOM 접근 side effect 가 먼저 터질 수 있다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { Widget } from './ui';
        \\export function render() {
        \\  return Widget;
        \\}
        \\globalThis.__zntcRender = render;
    );
    try writeFile(tmp.dir, "ui.js",
        \\globalThis.__zntcUiWasRequired = true;
        \\exports.Widget = 'widget-ready';
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const ui = try absPath(&tmp, "ui.js");
    defer std.testing.allocator.free(ui);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
        .strict_execution_order = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const eager_ui_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "__zntc_modules[\"{s}\"].fn();",
        .{ui},
    );
    defer std.testing.allocator.free(eager_ui_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, eager_ui_init) == null);

    const lazy_widget = try std.fmt.allocPrint(
        std.testing.allocator,
        "__zntc_modules[\"{s}\"].fn().Widget",
        .{ui},
    );
    defer std.testing.allocator.free(lazy_widget);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_widget) != null);
}

test "react_native inlineRequires: named re-export initializes canonical source at use site" {
    // `import { createStackNavigator } from '@react-navigation/stack'` 형태의
    // named re-export는 barrel 모듈이 아니라 실제 default export source를 실행해야
    // canonical binding이 undefined로 남지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { createStackNavigator } from './stack';
        \\globalThis.__zntcStackNavigator = createStackNavigator().ready;
    );
    try tmp.dir.makePath("stack");
    try writeFile(tmp.dir, "stack/index.js",
        \\export { default as createStackNavigator } from './createStackNavigator';
    );
    try writeFile(tmp.dir, "stack/createStackNavigator.js",
        \\export default function createStackNavigator() {
        \\  return { ready: 'stack-ready' };
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const barrel = try absPath(&tmp, "stack/index.js");
    defer std.testing.allocator.free(barrel);
    const source = try absPath(&tmp, "stack/createStackNavigator.js");
    defer std.testing.allocator.free(source);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const chained_lazy_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "(__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), __zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), createStackNavigator)",
        .{ barrel, source },
    );
    defer std.testing.allocator.free(chained_lazy_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, chained_lazy_init) != null);
}

test "react_native inlineRequires: named re-export preserves package entry side effects" {
    // RNFirebase perf 축소 재현:
    // package entry가 namespace side effect를 등록하고 named modular API를 re-export한다.
    // canonical source만 init하면 getPerformance 함수는 있어도 getApp().perf가 없다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("perf");
    try writeFile(tmp.dir, "entry.js",
        \\import { getPerformance } from './perf';
        \\globalThis.__zntcPerfResult = getPerformance().dataCollectionEnabled;
    );
    try writeFile(tmp.dir, "app.js",
        \\export function getApp() {
        \\  return globalThis.__zntcFirebaseApp;
        \\}
    );
    try writeFile(tmp.dir, "perf/index.js",
        \\import { registerPerf } from './registerPerf';
        \\registerPerf();
        \\export * from './modular';
    );
    try writeFile(tmp.dir, "perf/registerPerf.js",
        \\export function registerPerf() {
        \\  globalThis.__zntcFirebaseApp = {
        \\    perf() {
        \\      return { dataCollectionEnabled: 'perf-ready' };
        \\    },
        \\  };
        \\}
    );
    try writeFile(tmp.dir, "perf/modular.js",
        \\import { getApp } from '../app';
        \\export function getPerformance() {
        \\  return getApp().perf();
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const package_entry = try absPath(&tmp, "perf/index.js");
    defer std.testing.allocator.free(package_entry);
    const modular = try absPath(&tmp, "perf/modular.js");
    defer std.testing.allocator.free(modular);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const chained_lazy_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "(__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), __zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), getPerformance)",
        .{ package_entry, modular },
    );
    defer std.testing.allocator.free(chained_lazy_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, chained_lazy_init) != null);
}

test "react_native inlineRequires: namespace member rewrite initializes source modules" {
    // Sentry.init / modalSelectors.getFoo 축소 재현:
    // `import * as ns` 뒤의 `ns.member` 직접 치환도 namespace object getter와 동일하게
    // package entry와 canonical export source를 init해야 binding이 undefined로 남지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("sentry");
    try writeFile(tmp.dir, "entry.js",
        \\import * as Sentry from './sentry';
        \\import * as selectors from './selectors';
        \\globalThis.__zntcSelector = selectors.getVisible;
        \\globalThis.__zntcPromise = Promise.resolve().then(() => Sentry.init());
    );
    try writeFile(tmp.dir, "sentry/index.js",
        \\globalThis.__zntcSentryEntry = true;
        \\export { init } from './sdk';
    );
    try writeFile(tmp.dir, "sentry/sdk.js",
        \\export function init() {
        \\  return globalThis.__zntcSentryEntry;
        \\}
    );
    try writeFile(tmp.dir, "selectors.js",
        \\export const getVisible = (state) => state.visible;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const package_entry = try absPath(&tmp, "sentry/index.js");
    defer std.testing.allocator.free(package_entry);
    const sdk = try absPath(&tmp, "sentry/sdk.js");
    defer std.testing.allocator.free(sdk);
    const selectors = try absPath(&tmp, "selectors.js");
    defer std.testing.allocator.free(selectors);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const sentry_member_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "(__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), __zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), init)()",
        .{ package_entry, sdk },
    );
    defer std.testing.allocator.free(sentry_member_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, sentry_member_init) != null);

    const selector_member_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "(__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), getVisible)",
        .{selectors},
    );
    defer std.testing.allocator.free(selector_member_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, selector_member_init) != null);
}

test "react_native release: namespace member rewrite initializes export-star source modules" {
    // ProductTabContainer/modalSelectors 축소 재현:
    // release(tree_shaking=true) 에서 `import * as selectors from './selectors'`
    // 뒤 `selectors.getVisible` 을 직접 binding 으로 rewrite 할 때, export-star
    // barrel 자체가 아니라 실제 getter source 모듈도 init 해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("selectors");
    try writeFile(tmp.dir, "entry.js",
        \\import * as selectors from './selectors';
        \\globalThis.__zntcSelectorResult = selectors.getVisible({ modal: { visible: true } });
    );
    try writeFile(tmp.dir, "selectors/index.js",
        \\export * from './product';
    );
    try writeFile(tmp.dir, "selectors/product.js",
        \\export const getVisible = (state) => state.modal.visible;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = true,
        .dev_mode = false,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_product") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return init_product") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ", getVisible)") != null);
}

test "react_native inlineRequires: namespace import from export-star barrel initializes source getters" {
    // react-native-animatable 축소 재현:
    // `import * as defs from './definitions'`를 값으로 넘기면 namespace object가
    // 만들어진다. barrel의 `export *` source를 getter에서 init하지 않으면
    // Object.keys(defs) 이후 defs[name] 값이 undefined로 남는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("definitions");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ANIMATION_DEFINITIONS from './definitions';
        \\globalThis.__zntcAnimations = Object.keys(ANIMATION_DEFINITIONS)
        \\  .map((name) => ANIMATION_DEFINITIONS[name].label)
        \\  .join(',');
    );
    try writeFile(tmp.dir, "definitions/index.js",
        \\export * from './fading';
        \\export * from './bouncing';
    );
    try writeFile(tmp.dir, "definitions/fading.js",
        \\export const fadeIn = { label: 'fadeIn' };
    );
    try writeFile(tmp.dir, "definitions/bouncing.js",
        \\export const bounceIn = { label: 'bounceIn' };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const fading = try absPath(&tmp, "definitions/fading.js");
    defer std.testing.allocator.free(fading);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const getter_with_source_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "get fadeIn() {{ return (__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), fadeIn); }}",
        .{fading},
    );
    defer std.testing.allocator.free(getter_with_source_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, getter_with_source_init) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "get fadeIn() { return fadeIn; }") == null);
}

test "react_native inlineRequires: keeps default ESM imports eager for provider side effects" {
    // Metro inlineRequires 는 `import Foo from './foo'` 를 named import 처럼
    // `require(...).Foo` 위치로 미루지 않는다. RNFirebase Firestore 는 default
    // import 된 모듈의 top-level provider 호출로 DocumentReference 내부 slot 을
    // 채우므로 default import 를 lazy 처리하면 `new null.prototype` 계열 런타임
    // 오류가 난다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { makeDoc } from './firestore-index';
        \\globalThis.__zntcFirestoreDocResult = makeDoc();
    );
    try writeFile(tmp.dir, "firestore-index.js",
        \\import FirestoreQuery from './FirestoreQuery';
        \\import FirestoreDocumentReference from './FirestoreDocumentReference';
        \\export function makeQuery() {
        \\  return new FirestoreQuery();
        \\}
        \\export function makeDoc() {
        \\  return new FirestoreDocumentReference().get();
        \\}
    );
    try writeFile(tmp.dir, "FirestoreQuery.js",
        \\import FirestoreDocumentSnapshot from './FirestoreDocumentSnapshot';
        \\export default class FirestoreQuery {
        \\  snapshot() {
        \\    return new FirestoreDocumentSnapshot().name;
        \\  }
        \\}
    );
    try writeFile(tmp.dir, "FirestoreDocumentSnapshot.js",
        \\import { provideDocumentSnapshotClass } from './FirestoreDocumentReference';
        \\export default class FirestoreDocumentSnapshot {
        \\  constructor() {
        \\    this.name = 'snapshot-ready';
        \\  }
        \\}
        \\provideDocumentSnapshotClass(FirestoreDocumentSnapshot);
    );
    try writeFile(tmp.dir, "FirestoreDocumentReference.js",
        \\let FirestoreDocumentSnapshot = null;
        \\export function provideDocumentSnapshotClass(cls) {
        \\  FirestoreDocumentSnapshot = cls;
        \\}
        \\export default class FirestoreDocumentReference {
        \\  get() {
        \\    return new FirestoreDocumentSnapshot().name;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const query = try absPath(&tmp, "FirestoreQuery.js");
    defer std.testing.allocator.free(query);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const eager_query_init = try std.fmt.allocPrint(
        std.testing.allocator,
        "__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn();}});",
        .{query},
    );
    defer std.testing.allocator.free(eager_query_init);
    try std.testing.expect(std.mem.indexOf(u8, result.output, eager_query_init) != null);

    const lazy_query_value = try std.fmt.allocPrint(
        std.testing.allocator,
        "(__zntc_guarded(function(){{return __zntc_modules[\"{s}\"].fn()}}), FirestoreQuery)",
        .{query},
    );
    defer std.testing.allocator.free(lazy_query_value);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_query_value) == null);
}

test "react_native inlineRequires: object parameter default visits ESM value import" {
    // `{ backgroundColor = COLOR_TOKENS.bgPrimary }` 는 binding pattern 이지만
    // default initializer 는 값 표현식이다. Metro/Babel 은 이 import 를 값 참조로
    // 남기므로 zntc 도 lazy ESM import 치환을 적용해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { TabTemplate } from './template';
        \\globalThis.__zntcParamDefaultResult = TabTemplate({});
    );
    try writeFile(tmp.dir, "tokens.js",
        \\export const COLOR_TOKENS = { bgPrimary: 'primary-bg' };
    );
    try writeFile(tmp.dir, "template.js",
        \\import { COLOR_TOKENS } from './tokens';
        \\export const TabTemplate = ({ backgroundColor = COLOR_TOKENS.bgPrimary }) => backgroundColor;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const tokens = try absPath(&tmp, "tokens.js");
    defer std.testing.allocator.free(tokens);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "backgroundColor=COLOR_TOKENS.bgPrimary") == null);

    const lazy_tokens_value = try formatLazyMarker(std.testing.allocator, "backgroundColor", tokens, "COLOR_TOKENS", "bgPrimary");
    defer std.testing.allocator.free(lazy_tokens_value);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_tokens_value) != null);
}

test "react_native inlineRequires: simple parameter default visits ESM value import" {
    // `function f(a = X.y)` — assignment_pattern at the formal parameter level.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { format } from './fmt';
        \\globalThis.__zntcParamDefaultResult = format();
    );
    try writeFile(tmp.dir, "tokens.js",
        \\export const TOKENS = { primary: 'primary-default' };
    );
    try writeFile(tmp.dir, "fmt.js",
        \\import { TOKENS } from './tokens';
        \\export function format(color = TOKENS.primary) { return color; }
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const tokens = try absPath(&tmp, "tokens.js");
    defer std.testing.allocator.free(tokens);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "color=TOKENS.primary") == null);

    const lazy = try formatLazyMarker(std.testing.allocator, "color", tokens, "TOKENS", "primary");
    defer std.testing.allocator.free(lazy);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy) != null);
}

test "react_native inlineRequires: minified bare parameter default visits ESM value import" {
    // `function f(a = IMPORTED_CONST)` — release/minify 에서 bare named import
    // default initializer 의 symbol_id 가 빠지면 import 원본 이름이 전역 조회로
    // 남아 RN 런타임에서 ReferenceError 가 난다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import useThrottleEventHandler from './hook';
        \\globalThis.__zntcBareParamDefaultResult = useThrottleEventHandler();
    );
    try writeFile(tmp.dir, "ui.js",
        \\export const DEFAULT_THROTTLE_MILLISECONDS = 2000;
    );
    try writeFile(tmp.dir, "hook.js",
        \\import { DEFAULT_THROTTLE_MILLISECONDS } from './ui';
        \\const useThrottleEventHandler = (throttleTime = DEFAULT_THROTTLE_MILLISECONDS) => throttleTime;
        \\export default useThrottleEventHandler;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .entry_error_guard = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=DEFAULT_THROTTLE_MILLISECONDS") == null);
}

test "react_native inlineRequires: array pattern default visits ESM value import" {
    // `function f([a = X.y])` — array_pattern element default.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { pick } from './pick';
        \\globalThis.__zntcParamDefaultResult = pick([]);
    );
    try writeFile(tmp.dir, "tokens.js",
        \\export const TOKENS = { primary: 'arr-default' };
    );
    try writeFile(tmp.dir, "pick.js",
        \\import { TOKENS } from './tokens';
        \\export function pick([first = TOKENS.primary] = []) { return first; }
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const tokens = try absPath(&tmp, "tokens.js");
    defer std.testing.allocator.free(tokens);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // bare `=TOKENS.primary` 가 남으면 lazy 치환 누락.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "=TOKENS.primary") == null);

    // lazy expression 일부가 등장해야 한다 — array element default 위치.
    const lazy_marker = try formatLazyMarker(std.testing.allocator, "", tokens, "TOKENS", "primary");
    defer std.testing.allocator.free(lazy_marker);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_marker) != null);
}

test "react_native inlineRequires: nested destructuring default visits ESM value import" {
    // `function f({ a: { b = X.y } = {} })` — nested object inside object default.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { render } from './render';
        \\globalThis.__zntcParamDefaultResult = render({});
    );
    try writeFile(tmp.dir, "tokens.js",
        \\export const TOKENS = { primary: 'nested-default' };
    );
    try writeFile(tmp.dir, "render.js",
        \\import { TOKENS } from './tokens';
        \\export function render({ style: { color = TOKENS.primary } = {} } = {}) { return color; }
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const tokens = try absPath(&tmp, "tokens.js");
    defer std.testing.allocator.free(tokens);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "color=TOKENS.primary") == null);

    const lazy = try formatLazyMarker(std.testing.allocator, "color", tokens, "TOKENS", "primary");
    defer std.testing.allocator.free(lazy);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy) != null);
}

test "react_native inlineRequires: TS parameter property default visits ESM value import" {
    // `class C { constructor(public a = X.y) {} }` — TS access modifier 가
    // `formal_parameter` wrap 을 만드는 분기. 240bba46 의 formal_parameter
    // extra layout 분기를 정확히 잠근다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\import { Theme } from './theme';
        \\(globalThis as any).__zntcParamDefaultResult = new Theme();
    );
    try writeFile(tmp.dir, "tokens.ts",
        \\export const TOKENS = { primary: 'ts-param-prop-default' };
    );
    try writeFile(tmp.dir, "theme.ts",
        \\import { TOKENS } from './tokens';
        \\export class Theme {
        \\  constructor(public color: string = TOKENS.primary) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const tokens = try absPath(&tmp, "tokens.ts");
    defer std.testing.allocator.free(tokens);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // lazy guard 안의 `TOKENS).primary` 가 등장하면 raw `TOKENS.primary`
    // 는 어디에도 남지 않아야 한다 — class lowering 으로 default 가
    // `if (color === void 0)` 형태로 풀릴 수 있어 prefix 는 다양하니
    // raw bare 부재 한 가지로 잠근다.
    const lazy_marker = try formatLazyMarker(std.testing.allocator, "", tokens, "TOKENS", "primary");
    defer std.testing.allocator.free(lazy_marker);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_marker) != null);

    // raw `TOKENS.primary` 가 lazy_marker 외부에 남지 않았는지 — marker 안의
    // `TOKENS).primary` 는 닫는 `)` 가 끼어 있어 substring 매칭 안 됨.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TOKENS.primary") == null);
}

test "react_native inlineRequires: for-of binding default visits ESM value import" {
    // `for (const { a = X.y } of arr)` — `registerBinding` 경로의 default
    // visit.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.js",
        \\import { run } from './run';
        \\globalThis.__zntcParamDefaultResult = run([{}, {}]);
    );
    try writeFile(tmp.dir, "tokens.js",
        \\export const TOKENS = { primary: 'for-of-default' };
    );
    try writeFile(tmp.dir, "run.js",
        \\import { TOKENS } from './tokens';
        \\export function run(items) {
        \\  const out = [];
        \\  for (const { color = TOKENS.primary } of items) {
        \\    out.push(color);
        \\  }
        \\  return out;
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    const tokens = try absPath(&tmp, "tokens.js");
    defer std.testing.allocator.free(tokens);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .tree_shaking = false,
        .dev_mode = true,
        .entry_error_guard = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "color=TOKENS.primary") == null);

    const lazy_marker = try formatLazyMarker(std.testing.allocator, "", tokens, "TOKENS", "primary");
    defer std.testing.allocator.free(lazy_marker);
    try std.testing.expect(std.mem.indexOf(u8, result.output, lazy_marker) != null);
}
