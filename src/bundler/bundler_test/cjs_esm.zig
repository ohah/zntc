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
// CJS Wrapping Tests
// ============================================================

test "CJS: single CJS module wrapped with __commonJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = { value: 42 };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __commonJS 런타임 헬퍼가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    // require_lib 변수명이 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
    // module.exports가 래핑 내부에 유지되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "CJS: Object.defineProperty(module, exports) wrapped with __commonJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "const lib = require('./lib.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "lib.js",
        \\function getExports() { return { value: 123 }; }
        \\Object.defineProperty(module, "exports", { enumerable: true, get: getExports });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var require_lib = __commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Object.defineProperty(module, \"exports\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var init_lib = __esm") == null);
}

test "CJS: ESM imports default from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require_lib() 호출이 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib()") != null);
}

test "CJS: ESM imports named from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from './lib.cjs';\nconsole.log(value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require_lib()와 .value 접근이 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".value") != null);
}

test "CJS: RN strict order eagerly evaluates named CJS import before importer body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "setup.js",
        \\globalThis.order = [];
        \\globalThis.phase = 'before';
    );
    try writeFile(tmp.dir, "lib.cjs",
        \\globalThis.order.push(globalThis.phase);
        \\exports.value = 'value';
    );
    try writeFile(tmp.dir, "entry.js",
        \\import './setup.js';
        \\import { value } from './lib.cjs';
        \\globalThis.phase = 'after';
        \\console.log(value + ':' + globalThis.order.join(','));
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .platform = .react_native,
        .strict_execution_order = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const node_result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "node", "-e", result.output },
        .max_output_bytes = 16 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(node_result.stdout);
    defer std.testing.allocator.free(node_result.stderr);

    switch (node_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("node stderr:\n{s}\n", .{node_result.stderr});
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("node stderr:\n{s}\n", .{node_result.stderr});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqualStrings("value:before\n", node_result.stdout);
}

test "CJS: RN strict order skips named import used only as TS type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "types.cjs",
        \\globalThis.typeOnlyImportShouldNotRun = true;
        \\exports.T = String;
    );
    try writeFile(tmp.dir, "entry.tsx",
        \\import { T } from './types.cjs';
        \\export const value: T = 'ok';
        \\export const App = () => <>{value}</>;
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .strict_execution_order = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_types();") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "typeOnlyImportShouldNotRun") == null);
}

test "CJS: no runtime helper when no CJS modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 순수 ESM이면 __commonJS 런타임이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
}

test "CJS: mixed ESM and CJS modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './esm';
        \\import cjs from './lib.cjs';
        \\console.log(x, cjs);
    );
    try writeFile(tmp.dir, "esm.ts", "export const x = 'esm';");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 'cjs';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM 모듈은 스코프 호이스팅 (import 제거)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = \"esm\"") != null);
    // CJS 모듈은 __commonJS 래핑
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
}

test "CJS: require chain (CJS requires CJS)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import a from './a.cjs';\nconsole.log(a);");
    try writeFile(tmp.dir, "a.cjs", "const b = require('./b.cjs');\nmodule.exports = b + 1;");
    try writeFile(tmp.dir, "b.cjs", "module.exports = 10;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 CJS 모듈 모두 래핑되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_b") != null);
}

test "CJS: namespace import from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as lib from './lib.cjs';\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
}

test "CJS: multiple named imports from same CJS module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add, subtract } from './math.cjs';
        \\console.log(add(1, 2), subtract(3, 1));
    );
    try writeFile(tmp.dir, "math.cjs",
        \\exports.add = function(a, b) { return a + b; };
        \\exports.subtract = function(a, b) { return a - b; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_math") != null);
    // named import preamble에 add, subtract 모두 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".subtract") != null);
}

test "CJS: aliased named import from CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value as v } from './lib.cjs';\nconsole.log(v);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib") != null);
}

test "CJS: minified CJS wrapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // #1618: minify 모드에서 CJS 팩토리는 `$c`로 축약 (#3256 후 1 char 단축)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$c=") != null);
    // 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "CJS: special characters in module path sanitized" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './my-lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "my-lib.cjs", "module.exports = 'hello';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 하이픈이 _로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_my_lib") != null);
}

test "CJS: ESM module importing from both ESM and CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { esm } from './esm-dep';
        \\import { cjs } from './cjs-dep.cjs';
        \\console.log(esm, cjs);
    );
    try writeFile(tmp.dir, "esm-dep.ts", "export const esm = 'esm';");
    try writeFile(tmp.dir, "cjs-dep.cjs", "exports.cjs = 'cjs';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM dep은 스코프 호이스팅 (const esm 직접 노출)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const esm") != null);
    // CJS dep은 __commonJS 래핑
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjs_dep") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
}

test "CJS: empty CJS module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './empty.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "empty.cjs", "// empty module");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // .cjs 확장자이므로 CJS로 래핑됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_empty") != null);
}

test "CJS: default import from direct module.exports uses require fast path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs", "module.exports = function value() { return 42; };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "lib = require_lib();") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") == null);
}

test "CJS: __toESM not applied to named imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from './lib.cjs';\nconsole.log(value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // named import에는 __toESM 미적용 (require_lib().value 형태)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib().value") != null);
}

test "CJS: ExportsKind promotion — .js required becomes CJS" {
    // ExportsKind 승격을 그래프 테스트로 직접 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ESM 모듈이 require()로 plain .js 파일을 로드 (ESM+CJS 혼용)
    // plain.js는 module syntax가 없으므로 exports_kind=none → require()로 소비되어 CJS로 승격
    try writeFile(tmp.dir, "entry.ts", "import './esm_dep';\nconst lib = require('./plain');\nconsole.log(lib);");
    try writeFile(tmp.dir, "esm_dep.ts", "export const y = 2;");
    try writeFile(tmp.dir, "plain.js", "const x = 1;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // graph에서 plain.js 모듈을 찾아서 exports_kind 확인
    var plain_found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "plain.js")) {
            // require()로 소비되었으므로 CJS로 승격되어야 함
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            plain_found = true;
            break;
        }
    }
    try std.testing.expect(plain_found);
}

test "CJS: ExportsKind promotion — .js imported becomes ESM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ESM이 import로 plain .js 파일을 로드 → ESM으로 승격 (래핑 안 함)
    try writeFile(tmp.dir, "entry.ts", "import './plain.js';\nconst y = 2;");
    try writeFile(tmp.dir, "plain.js", "const x = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM import로 소비된 plain.js는 래핑되지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_plain") == null);
}

test "CJS: __toESM runtime helper injected with __commonJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __commonJS와 __toESM 런타임 헬퍼가 모두 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") != null);
}

test "CJS: __toESM not injected when no CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 순수 ESM 번들에는 __commonJS도 __toESM도 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") == null);
}

test "CJS: require overrides ESM promotion (both import and require same module)" {
    // 같은 .js 파일을 한쪽에서 import, 다른쪽에서 require() → require가 우선 (esbuild 동작)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './importer';
        \\import './requirer';
    );
    try writeFile(tmp.dir, "importer.ts", "import './shared.js';");
    try writeFile(tmp.dir, "requirer.ts", "const s = require('./shared.js');\nconsole.log(s);");
    try writeFile(tmp.dir, "shared.js", "const x = 1;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // shared.js는 import와 require 모두로 소비됨 → require가 우선이므로 CJS
    var shared_found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "shared.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            shared_found = true;
            break;
        }
    }
    try std.testing.expect(shared_found);
}

test "CJS: CJS module with both module.exports and exports.x" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs",
        \\exports.name = 'test';
        \\module.exports = { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") != null);
}

test "CJS: namespace import from CJS uses __toESM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as lib from './lib.cjs';\nconsole.log(lib.default, lib.value);");
    try writeFile(tmp.dir, "lib.cjs", "exports.value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace import도 __toESM으로 래핑 (.ts → Babel 모드)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") != null);
}

test "CJS: default import keeps __toESM when exports __esModule assignment exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs",
        \\exports.__esModule = true;
        \\module.exports = function value() { return 1; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib()).default") != null);
}

test "CJS: default import keeps __toESM when module.exports __esModule assignment exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs",
        \\module.exports = function value() { return 1; };
        \\module.exports.__esModule = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib()).default") != null);
}

test "CJS: default import keeps __toESM when defineProperty __esModule marker exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.cjs",
        \\Object.defineProperty(module.exports, "__esModule", { value: true });
        \\module.exports = function value() { return 1; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib()).default") != null);
}

test "CJS: React Native type module default import uses Babel interop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("node_modules/pkg");
    try writeFile(tmp.dir, "entry.cjs", "require('pkg');\n");
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"type":"module","react-native":"./widget.tsx","main":"./fallback.cjs"}
    );
    try writeFile(tmp.dir, "node_modules/pkg/widget.tsx", "import styled from './styled.cjs';\nexport const value = styled('View');\n");
    try writeFile(tmp.dir, "node_modules/pkg/styled.cjs",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = function styled(component) { return component; };
        \\exports.styled = exports.default;
    );

    const entry = try absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_pkg_styled()).default") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_pkg_styled(), 1).default") == null);
}

test "CJS: multiple ESM modules importing same CJS module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\import './b';
    );
    try writeFile(tmp.dir, "a.ts", "import lib from './shared.cjs';\nconsole.log(lib);");
    try writeFile(tmp.dir, "b.ts", "import { value } from './shared.cjs';\nconsole.log(value);");
    try writeFile(tmp.dir, "shared.cjs", "exports.value = 42;\nmodule.exports.default = exports;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared.cjs는 한 번만 래핑
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
}

test "CJS: esm_with_dynamic_fallback module required — promoted to ESM wrap (graph)" {
    // ESM+CJS 혼합 모듈(esm_with_dynamic_fallback)이 require()로 소비되면
    // ESM 의미론을 보존하면서 __esm 래핑 (esbuild WrapESM 모델).
    // exports_kind는 esm_with_dynamic_fallback 유지, wrap_kind는 .esm.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const h = require('./hybrid.js');\nconsole.log(h);");
    // hybrid.js: ESM(export) + CJS(require) 모두 사용 → esm_with_dynamic_fallback
    try writeFile(tmp.dir, "hybrid.js",
        \\export const value = 42;
        \\const other = require('./dep.js');
        \\module.exports = { value, other };
    );
    try writeFile(tmp.dir, "dep.js", "module.exports = 'dep';");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // hybrid.js: esm_with_dynamic_fallback + require 소비 → WrapKind.esm
    var hybrid_found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "hybrid.js")) {
            try std.testing.expectEqual(types.ExportsKind.esm_with_dynamic_fallback, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.esm, m.wrap_kind);
            hybrid_found = true;
            break;
        }
    }
    try std.testing.expect(hybrid_found);
}

test "CJS: esm_with_dynamic_fallback module required — wrapped in __esm (bundler)" {
    // 번들 출력에서 ESM+CJS 혼합 모듈이 __esm 래퍼로 감싸지는지 검증.
    // ESM 모듈이 require()로 소비 → WrapKind.esm → __esm 래핑.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const h = require('./hybrid.js');\nconsole.log(h);");
    try writeFile(tmp.dir, "hybrid.js",
        \\export const value = 42;
        \\const other = require('./dep.js');
        \\module.exports = { value, other };
    );
    try writeFile(tmp.dir, "dep.js", "module.exports = 'dep';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // hybrid.js가 __esm으로 래핑되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_hybrid") != null);
}

test "CJS: React Native mixed import plus module.exports uses Metro CJS wrapper" {
    // Metro+Babel은 RN .js 파일의 import를 require로 낮춘 뒤 CJS module wrapper에서
    // 실행한다. import + module.exports 혼용 파일을 __esm으로 감싸면 module이 없어져
    // @payhereinc/react-native-code-push/AlertAdapter.js 패턴이 부팅 중 실패한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import adapter from './AlertAdapter.js';\nconsole.log(adapter.Alert);");
    try writeFile(tmp.dir, "AlertAdapter.js",
        \\import React, { Platform } from './rn.js';
        \\let { Alert } = React;
        \\if (Platform.OS === 'android') Alert = {};
        \\module.exports = { Alert };
    );
    try writeFile(tmp.dir, "rn.js",
        \\export const Platform = { OS: 'ios' };
        \\export default { Alert: 'alert', Platform };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .react_native });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"AlertAdapter.js\"(exports, module)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var require_AlertAdapter = __commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var init_AlertAdapter = __esm") == null);
}

test "CJS: React Native missing named import is shimmed to undefined" {
    // Metro/Babel은 `require("./lib").missing` property access로 남겨 undefined를 반환한다.
    // RN 플랫폼에서 zntc가 strict ESM missing export처럼 free identifier를 만들면 런타임 ReferenceError가 난다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\import { missing } from './lib';
        \\class SDK {
        \\  static missing = missing;
        \\}
        \\console.log(SDK.missing);
    );
    try writeFile(tmp.dir, "lib.js", "export const existing = 42;");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "void 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "static missing = missing") == null);
}

test "CJS: ESM import inside __commonJS wrapper rewritten to require_xxx()" {
    // ESM 모듈이 require()로 소비되어 __commonJS 래핑될 때,
    // 내부 import 문이 require("specifier")로 변환되는데,
    // 이 변환된 require()도 require_xxx()로 치환되어야 한다.
    // (emitImportCJS에서 require_rewrites 맵 미참조 버그 수정 검증)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm-lib.js');\nconsole.log(lib);");
    // esm-lib.js: ESM import 사용, require()로 소비되어 CJS 래핑됨
    try writeFile(tmp.dir, "esm-lib.js",
        \\import helper from './helper.cjs';
        \\export function greet() { return helper(); }
    );
    try writeFile(tmp.dir, "helper.cjs", "module.exports = function() { return 'hello'; };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // esm-lib.js의 import helper from './helper.cjs'가
    // require_helper()로 변환되어야 함 (require("./helper.cjs")가 아님)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_helper") != null);
    // 번들 내에 raw require("./helper.cjs")가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./helper.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./helper.cjs')") == null);
}

test "CJS: side-effect import inside __commonJS wrapper rewritten to require_xxx()" {
    // side-effect import (import './foo') 도 require_xxx()로 변환되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./side-lib.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "side-lib.js",
        \\import './setup.cjs';
        \\export const value = 42;
    );
    try writeFile(tmp.dir, "setup.cjs", "global.__SETUP = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // side-effect import도 require_setup()으로 변환
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_setup") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./setup.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./setup.cjs')") == null);
}

test "CJS: named import inside __commonJS wrapper rewritten to require_xxx()" {
    // import { foo } from './bar' → const {foo}=require_bar(); (require("./bar") 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./named-lib.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "named-lib.js",
        \\import { value } from './util.cjs';
        \\export function compute() { return value * 2; }
    );
    try writeFile(tmp.dir, "util.cjs", "exports.value = 21;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_util") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./util.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./util.cjs')") == null);
}

test "CJS: scope hoisted esm_with_dynamic_fallback — internal require() rewritten" {
    // ESM+CJS 혼합 모듈이 import로 소비되어 scope hoisting될 때,
    // 내부 require() 호출이 require_xxx()로 변환되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry가 import로 소비 → hybrid.js는 ESM으로 승격 (scope hoisted)
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './hybrid.js';
        \\console.log(greet());
    );
    // hybrid.js: ESM(export) + CJS(require) → esm_with_dynamic_fallback, import로 소비 → scope hoisted
    try writeFile(tmp.dir, "hybrid.js",
        \\const dep = require('./dep.cjs');
        \\export function greet() { return dep(); }
    );
    try writeFile(tmp.dir, "dep.cjs", "module.exports = function() { return 'hi'; };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // scope hoisted 모듈 내부 require('./dep.cjs') → require_dep()
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_dep") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./dep.cjs\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./dep.cjs')") == null);
}

// ============================================================
// WrapKind.esm (__esm 래퍼) Tests
// ============================================================

test "ESM wrap: pure ESM module required — WrapKind.esm (graph)" {
    // 순수 ESM 모듈이 require()로 소비 → WrapKind.esm (CJS가 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm-mod.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "esm-mod.js",
        \\export function hello() { return 'world'; }
        \\export const value = 42;
    );

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "esm-mod.js")) {
            try std.testing.expectEqual(types.ExportsKind.esm, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.esm, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: CJS module required — still WrapKind.cjs (graph)" {
    // CJS 모듈은 require() 소비 시 WrapKind.cjs 유지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./cjs-mod.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "cjs-mod.js", "module.exports = { value: 42 };");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "cjs-mod.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: none module required — WrapKind.cjs (graph)" {
    // exports_kind == .none (ESM/CJS 신호 없음) + require 소비 → CJS
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./plain.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "plain.js", "const x = 1;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "plain.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: __esm runtime injected in bundle output" {
    // WrapKind.esm 모듈이 있으면 __esm 런타임이 번들에 주입되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm.js');\nconsole.log(lib);");
    try writeFile(tmp.dir, "esm.js", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_esm") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_esm") != null);
}

test "ESM wrap: CJS requires ESM — (init_xxx(), __toCommonJS(exports_xxx)) pattern" {
    // CJS 모듈에서 ESM 모듈을 require() → (init_xxx(), __toCommonJS(exports_xxx))
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs", "const lib = require('./esm.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "esm.js", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require("./esm.js")가 (init_esm(), __toCommonJS(exports_esm))으로 변환
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_esm()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toCommonJS(exports_esm)") != null);
    // raw require가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./esm.js\")") == null);
}

test "ESM wrap: 2-pass promotion — require before import" {
    // 같은 모듈을 import + require → require가 우선 (2-pass)
    // ESM 모듈이면 WrapKind.esm, import가 나중에 와도 변경 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './importer.ts';
        \\import './requirer.ts';
    );
    try writeFile(tmp.dir, "importer.ts", "import { value } from './shared.js';\nconsole.log(value);");
    try writeFile(tmp.dir, "requirer.ts", "const s = require('./shared.js');\nconsole.log(s);");
    try writeFile(tmp.dir, "shared.js", "export const value = 42;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry.ts" });
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    // shared.js: ESM + require 소비 → WrapKind.esm (import가 CJS로 덮어쓰지 않음)
    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "shared.js")) {
            try std.testing.expectEqual(types.WrapKind.esm, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM wrap: CJS wrapper imports scope-hoisted ESM — no raw require" {
    // CJS 래핑 모듈이 scope hoisted ESM 모듈을 import할 때
    // import가 skip되고 preamble/rename으로 직접 참조
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './lib.js';
        \\console.log(greet());
    );
    // lib.js: CJS (require 사용) → __commonJS 래핑
    try writeFile(tmp.dir, "lib.js",
        \\const helper = require('./helper.cjs');
        \\import { util } from './util.js';
        \\exports.greet = function() { return helper() + util(); };
    );
    try writeFile(tmp.dir, "helper.cjs", "module.exports = function() { return 'hi'; };");
    // util.js: 순수 ESM → scope hoisted
    try writeFile(tmp.dir, "util.js", "export function util() { return ' world'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require("./util.js")가 남아있으면 안 됨 (scope hoisted → 직접 참조)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./util.js\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('./util.js')") == null);
}

test "ESM wrap: namespace import of __esm module — canonical name direct rewrite" {
    // import * as ns from './esm-mod' → ns.prop → canonical name 직접 치환.
    // exports_xxx rename은 변수 덮어쓰기 버그를 유발하므로 사용하지 않음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as utils from './utils.js';
        \\console.log(utils.greet());
    );
    try writeFile(tmp.dir, "utils.js",
        \\export function greet() { return 'hello'; }
        \\export const value = 42;
    );
    // utils.js를 require로 소비하여 __esm 래핑
    try writeFile(tmp.dir, "requirer.ts", "const u = require('./utils.js');");
    try writeFile(tmp.dir, "main.ts",
        \\import './entry.ts';
        \\import './requirer.ts';
    );

    const main_entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(main_entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{main_entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace 멤버 접근이 canonical name으로 직접 치환: console.log(greet())
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(greet())") != null);
    // 원본 namespace 접근 형태가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "utils.greet") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_utils.greet") == null);
}

test "ESM wrap: skip_cjs_exports — no exports.x in __esm wrapper" {
    // __esm 래핑 모듈은 exports.x = x를 생성하면 안 됨 (__export가 대신 처리)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./esm.js');\nconsole.log(lib.value);");
    try writeFile(tmp.dir, "esm.js",
        \\export const value = 42;
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm 래퍼 안에 exports.value=value 또는 exports.greet=greet 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.value") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.greet") == null);
    // __export()가 존재해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") != null);
}

test "ESM wrap: export default named ref — no duplicate var" {
    // export default SomeVar → __esm에서 var SomeVar=SomeVar 중복 생성 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./mod.js');\nconsole.log(lib.default);");
    try writeFile(tmp.dir, "mod.js",
        \\const Platform = { OS: 'ios' };
        \\export default Platform;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // module.exports=Platform 직접 대입이 없어야 함 (__export가 처리)
    // __toCommonJS 런타임 헬퍼의 "module.exports"는 허용 (mod['module.exports'] 패턴)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports =") == null);
    // __export에서 default getter가 Platform을 참조
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Platform") != null);
}

test "ESM wrap: export default anonymous expr — var _default" {
    // export default {...} → var _default = {...};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./mod.js');\nconsole.log(lib.default);");
    try writeFile(tmp.dir, "mod.js",
        \\export default { value: 42 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // var _default = { value: 42 }; 형태
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_default") != null);
    // module.exports= 직접 대입이 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports =") == null);
}

test "ESM wrap: var hoisting + __export outside __esm (esbuild/rolldown 방식)" {
    // rolldown 방식: function은 __esm 밖으로 호이스팅 (live binding).
    // __export()는 래퍼 밖에서 lazy getter로 등록 (접근 시점에 변수 참조).
    // init은 의존 모듈 init 호출만 담당.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const lib = require('./mod.js');\nconsole.log(lib.greet());");
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
    // __export가 __esm 래퍼 밖(앞)에 있어야 함 (var 호이스팅 방식)
    const esm_start = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const export_pos = std.mem.indexOf(u8, result.output, "__export(") orelse unreachable;
    try std.testing.expect(export_pos < esm_start);
    // function greet()가 __esm 밖으로 호이스팅되어야 함 (rolldown 방식)
    const fn_pos = std.mem.indexOf(u8, result.output, "function greet()") orelse unreachable;
    try std.testing.expect(fn_pos < esm_start);
}

test "ESM wrap: Flow type cast + namespace import → ns_member_rewrite 적용" {
    // Flow 타입 캐스트 (expr: Type) 안의 namespace member access가
    // ns_member_rewrites로 올바르게 치환되는지 검증.
    // semantic analyzer가 flow_type_cast_expression 내부를 방문해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\export function getEnforcing(name) { return name + '_enforced'; }
    );
    try writeFile(tmp.dir, "native.js",
        \\// @flow
        \\import * as Registry from './registry.js';
        \\export default (Registry.getEnforcing('Test'): string);
    );
    try writeFile(tmp.dir, "cjs.js",
        \\const r = require('./registry.js');
        \\module.exports = r;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import val from './native.js';
        \\require('./cjs.js');
        \\console.log(val);
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
    // "Registry.getEnforcing"가 남아있으면 안 됨 (ns_member_rewrite 미적용)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Registry.getEnforcing") == null);
    // exports_registry.getEnforcing 또는 직접 getEnforcing으로 치환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "getEnforcing") != null);
}

test "ESM wrap: var hoisting + default export 접근 가능" {
    // __esm 래퍼의 var 호이스팅으로 default export가 외부에서 직접 접근 가능한지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\export const count = 42;
        \\export const name = 'hello';
    );
    try writeFile(tmp.dir, "wrapper.js",
        \\import * as Mod from './mod.js';
        \\export default Mod.count;
    );
    try writeFile(tmp.dir, "cjs.js",
        \\const m = require('./mod.js');
        \\module.exports = m;
    );
    try writeFile(tmp.dir, "entry.js",
        \\import val from './wrapper.js';
        \\require('./cjs.js');
        \\console.log(val);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // var 호이스팅: _default가 __esm 래퍼 밖에 선언
    // __esm({ 이전에 "var" 선언이 있어야 함
    const esm_pos = std.mem.indexOf(u8, result.output, "__esm({") orelse unreachable;
    const var_decl = std.mem.indexOf(u8, result.output, "var ");
    try std.testing.expect(var_decl != null and var_decl.? < esm_pos);
}

test "ESM wrap: class declaration hoisted as var (block-scope → assignment)" {
    // class 선언은 block-scoped → __esm 콜백 밖의 __export getter가 접근 불가.
    // var 선언을 밖에 두고 body에서 할당문으로 변환해야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "mod.js",
        \\export class Greeter {
        \\  greet() { return 'hello'; }
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\const m = require('./mod.js');
        \\console.log(m.Greeter);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // class가 var로 호이스팅되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var ") != null);
    // __esm body 안에서 할당문으로 변환: "Greeter = class Greeter"
    try std.testing.expect(std.mem.indexOf(u8, result.output, "= class Greeter") != null);
    // 선언문 형태가 아닌지 확인 (class Greeter { 가 __esm 안에서 단독으로 나오면 안 됨)
    // __export getter가 접근 가능해야 하므로 할당문이어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__export") != null);
}

// ============================================================
// Top-Level Await (TLA) Tests
// ============================================================

test "TLA: detected in module" {
    // top-level await가 있는 모듈은 uses_top_level_await=true가 되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const data = await fetch('/api');\nconsole.log(data);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // await 표현식이 번들 출력에 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fetch") != null);
}

test "TLA: not detected inside async function" {
    // async 함수 내부의 await는 TLA가 아니므로 경고가 없어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "async function load() { const x = await fetch('/api'); return x; }\nconsole.log(load);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: TLA가 없으므로 경고 주석이 없어야 함
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // async 함수 내부 await는 TLA가 아님 → 경고 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZNTC0002]") == null);
}

test "TLA: propagated to importer" {
    // B가 TLA를 사용하고, A가 B를 static import하면
    // A도 TLA로 전파되어야 한다 (import 체인 전파).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "const data = await Promise.resolve(42);\nconsole.log(data);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: A가 B(TLA)를 import → A도 TLA → 경고 발생
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // TLA 전파 → CJS에서 경고 주석 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZNTC0002]") != null);
}

test "TLA: not propagated via dynamic import" {
    // 동적 import는 비동기이므로 TLA를 전파하지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const mod = import('./b');\nconsole.log(mod);");
    try writeFile(tmp.dir, "b.ts", "const data = await Promise.resolve(42);\nexport default data;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: 동적 import → TLA 비전파 → 경고 없음
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 동적 import는 TLA 전파 안 함 → 경고 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZNTC0002]") == null);
}

test "TLA: warning for CJS output" {
    // CJS 포맷에서 TLA 사용 시 경고 주석이 삽입되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const x = await Promise.resolve(1);\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZNTC0002] Top-level await requires ESM output format.") != null);
    // 중복 경고 방지: 정확히 한 번만 emit되어야 함 (이전엔 iife/umd/amd prologue가 추가로 emit했음)
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.output, "[ZNTC0002]"));
}

test "TLA: no warning for ESM output" {
    // ESM 포맷에서는 TLA가 정상이므로 경고가 없어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const x = await Promise.resolve(1);\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // ESM → 경고 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZNTC0002]") == null);
}

test "TLA: for-await-of detected" {
    // `for await (const x of gen) {}` 는 TLA이다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\async function* gen() { yield 1; yield 2; }
        \\for await (const x of gen()) { console.log(x); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // CJS 포맷: for-await-of는 TLA → 경고 발생
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZNTC0002]") != null);
}

test "TLA: await inside object literal at top level" {
    // 이전 containsAwait 구현에서 object_expression을 누락하여 감지 실패했던 케이스
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const config = { data: await fetch('/api') };
        \\export default config;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // object literal 내부 await도 TLA로 감지 → CJS 경고
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZNTC0002") != null);
}

test "TLA: await inside array literal at top level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const items = [await fetch('/a'), await fetch('/b')];
        \\export default items;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZNTC0002") != null);
}

test "TLA: await inside ternary expression at top level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const val = true ? await fetch('/a') : null;
        \\export default val;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZNTC0002") != null);
}

test "TLA: for_await_of_statement detected via AST tag" {
    // isForAwaitOf 소스 텍스트 스캔 대신 파서가 for_await_of_statement 태그를 생성하여 감지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\async function* gen() { yield 1; yield 2; }
        \\for await (const x of gen()) { console.log(x); }
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // for await 감지 → CJS 경고
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZNTC0002") != null);
    // codegen이 for await of를 올바르게 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for await") != null);
}

// ============================================================
// Regression: Flow type-only import must not affect CJS detection
// ============================================================

test "CJS: Flow import typeof does not make CJS module ESM (regression)" {
    // Regression: 7ac17fd inline scan에서 has_module_syntax가 type-only import에도 설정되어
    // react-native/index.js (import typeof + module.exports) 패턴이 ESM으로 오판됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './rn.js';\nconsole.log(lib);");
    try writeFile(tmp.dir, "rn.js",
        \\import typeof Foo from './types.js';
        \\const warnOnce = require('./warn.js');
        \\module.exports = { get View() { return 'View'; } };
    );
    try writeFile(tmp.dir, "types.js", "export type Foo = string;");
    try writeFile(tmp.dir, "warn.js", "module.exports = function() {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.flow = true;
    try graph.build(&.{entry});

    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "rn.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CJS: Flow import typeof with module.exports produces __commonJS wrapper" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './rn.js';\nconsole.log(lib);");
    try writeFile(tmp.dir, "rn.js",
        \\import typeof * as API from './types.js';
        \\module.exports = { value: 42 };
    );
    try writeFile(tmp.dir, "types.js", "export type API = {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .flow = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

test "CJS: TS import type does not make CJS module ESM" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './lib.js';\nconsole.log(lib);");
    try writeFile(tmp.dir, "lib.js",
        \\import type { Foo } from './types.js';
        \\module.exports = { value: 1 };
    );
    try writeFile(tmp.dir, "types.js", "export type Foo = string;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "lib.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CJS: export type re-export + module.exports stays CJS (regression)" {
    // ReactNativePrivateInterface.js 패턴: export type { ... } from + module.exports
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './rn-private.js';\nconsole.log(lib);");
    try writeFile(tmp.dir, "rn-private.js",
        \\export type { Foo } from './types.js';
        \\module.exports = { get BatchedBridge() { return require('./bridge.js'); } };
    );
    try writeFile(tmp.dir, "types.js", "export type Foo = string;");
    try writeFile(tmp.dir, "bridge.js", "module.exports = {};");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var found = false;
    var it = graph.modulesIterator();
    while (it.next()) |m| {
        if (std.mem.endsWith(u8, m.path, "rn-private.js")) {
            try std.testing.expectEqual(types.ExportsKind.commonjs, m.exports_kind);
            try std.testing.expectEqual(types.WrapKind.cjs, m.wrap_kind);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "ESM re-export: named re-export from CJS binds via require getter (#1425)" {
    // RN AssetRegistry 패턴: 래핑된 source의 exports를 getter가 직접 참조해야
    // ReferenceError 회피.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\const assets = [];
        \\function registerAsset(asset) { return assets.push(asset); }
        \\function getAssetByID(id) { return assets[id - 1]; }
        \\module.exports = { registerAsset, getAssetByID };
    );
    try writeFile(tmp.dir, "AssetRegistry.js",
        \\export { registerAsset, getAssetByID } from './registry.js';
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { registerAsset } from './AssetRegistry.js';
        \\registerAsset({ name: 'test' });
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
    // __export getter가 require_registry().X 패턴을 사용해야 함 (자유변수 참조 X)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_registry().registerAsset") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_registry().getAssetByID") != null);
}

test "CJS raw require namespace keeps lazy getter require target" {
    // ReactNativePrivateInterface pattern: a CJS namespace is read through raw
    // require(), then one getter property lazily requires another module. The
    // namespace read makes every getter observable, including Flow-typed getter
    // bodies that have no direct named export use yet.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "rn-private.js",
        \\// @flow strict-local
        \\import typeof ReactFiberErrorDialog from './dialog.js';
        \\
        \\module.exports = {
        \\  get ReactFiberErrorDialog(): ReactFiberErrorDialog {
        \\    return require('./dialog.js').default;
        \\  },
        \\};
    );
    try writeFile(tmp.dir, "dialog.js",
        \\// @flow strict-local
        \\export type CapturedError = {
        \\  +componentStack: string,
        \\  +error: mixed,
        \\};
        \\
        \\const ReactFiberErrorDialog = {
        \\  showErrorDialog(_capturedError: CapturedError): boolean {
        \\    return false;
        \\  },
        \\};
        \\export default ReactFiberErrorDialog;
    );
    try writeFile(tmp.dir, "renderer.js",
        \\const iface = require('./rn-private.js');
        \\if (typeof iface.ReactFiberErrorDialog.showErrorDialog !== 'function') {
        \\  throw new Error('missing dialog');
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\require('./renderer.js');
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .flow = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "showErrorDialog") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "missing dialog") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return !1") != null or
        std.mem.indexOf(u8, result.output, "return!1") != null);
}

test "ESM re-export: CJS require member access keeps re-export source body" {
    // RN asset loader pattern: generated asset modules call
    // `require("AssetRegistry").registerAsset(...)`. The raw require observes
    // the ESM facade namespace, so the facade's CJS re-export source must also
    // keep the actual export fact body.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\const assets = [];
        \\function registerAsset(asset) { assets.push(asset); return assets.length; }
        \\function getAssetByID(id) { return assets[id - 1]; }
        \\module.exports = { registerAsset, getAssetByID };
    );
    try writeFile(tmp.dir, "AssetRegistry.js",
        \\export { registerAsset, getAssetByID } from './registry.js';
    );
    try writeFile(tmp.dir, "asset.js",
        \\module.exports = require('./AssetRegistry.js').registerAsset({ name: 'test' });
    );
    try writeFile(tmp.dir, "entry.js",
        \\const asset = require('./asset.js');
        \\globalThis.asset = asset;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "registerAsset(asset)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = { registerAsset, getAssetByID }") != null);
}

test "RN asset registry: scale-only asset keeps Metro base name and scale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\exports.registerAsset = function registerAsset(asset) { return asset; };
    );
    try writeFile(tmp.dir, "AssetRegistry.js",
        \\export { registerAsset } from './registry.js';
    );
    try writeFile(tmp.dir, "assets.ts",
        \\import Poster from './poster@3x.webp';
        \\export { Poster };
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { Poster } from './assets';
        \\console.log(Poster);
    );
    try writeFile(tmp.dir, "poster@3x.webp", "webp");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .asset_registry = "./AssetRegistry.js",
        .loader_overrides = &.{.{ .ext = ".webp", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return default;") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"name\": \"poster\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scales\": [3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"name\": \"poster@3x\"") == null);
}

test "RN asset registry: base asset import resolves scale-only sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\exports.registerAsset = function registerAsset(asset) { return asset; };
    );
    try writeFile(tmp.dir, "AssetRegistry.js",
        \\export { registerAsset } from './registry.js';
    );
    try writeFile(tmp.dir, "assets.ts",
        \\import Poster from './poster.webp';
        \\export { Poster };
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { Poster } from './assets';
        \\console.log(Poster);
    );
    try writeFile(tmp.dir, "poster@3x.webp", "webp");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .asset_registry = "./AssetRegistry.js",
        .loader_overrides = &.{.{ .ext = ".webp", .loader = .file }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return default;") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./poster.webp\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"name\": \"poster\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scales\": [3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"name\": \"poster@3x\"") == null);
}

test "ESM namespace import: CJS named re-export member binds via require getter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "registry.js",
        \\exports.setTag = function setTag(value) { globalThis.tag = value; };
    );
    try writeFile(tmp.dir, "facade.js",
        \\export { setTag } from './registry.js';
    );
    try writeFile(tmp.dir, "entry.js",
        \\import * as facade from './facade.js';
        \\facade.setTag('ok');
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_registry().setTag(\"ok\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\nsetTag(\"ok\")") == null);
}

test "ESM re-export: named re-export from ESM binds via exports getter (#1425)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "source.js",
        \\export function helper() { return 42; }
    );
    try writeFile(tmp.dir, "barrel.js",
        \\export { helper } from './source.js';
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { helper } from './barrel.js';
        \\console.log(helper());
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
    // ESM 래핑 source: exports_source.helper 패턴
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_source.helper") != null);
}

test "RN namespace re-export: type-only neighbor keeps value getter live" {
    // reanimated hook/index.ts 축소 재현. 같은 source의 type-only re-export 옆에
    // value re-export가 있고, 소비자가 namespace.member로 읽어도 source getter가 살아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/react-native-reanimated/package.json",
        \\{
        \\  "name": "react-native-reanimated",
        \\  "react-native": "src/index.ts",
        \\  "sideEffects": ["./src/index.ts"]
        \\}
    );
    try writeFile(tmp.dir, "node_modules/react-native-gesture-handler/package.json",
        \\{
        \\  "name": "react-native-gesture-handler",
        \\  "main": "src/index.ts"
        \\}
    );
    try writeFile(tmp.dir, "node_modules/react-native-reanimated/src/hook/useEvent.ts",
        \\export type EventHandler = () => void;
        \\export function useEvent() { return 'event'; }
    );
    try writeFile(tmp.dir, "node_modules/react-native-reanimated/src/hook/useSharedValue.ts",
        \\export function useSharedValue() { return 'shared'; }
    );
    try writeFile(tmp.dir, "node_modules/react-native-reanimated/src/hook/index.ts",
        \\export type { EventHandler } from './useEvent';
        \\export { useEvent } from './useEvent';
        \\export { useSharedValue } from './useSharedValue';
    );
    try writeFile(tmp.dir, "node_modules/react-native-reanimated/src/index.ts",
        \\export { useEvent, useSharedValue } from './hook';
    );
    try writeFile(tmp.dir, "node_modules/react-native-gesture-handler/src/reanimatedWrapper.ts",
        \\let Reanimated;
        \\try {
        \\  Reanimated = require('react-native-reanimated');
        \\} catch (e) {
        \\  Reanimated = undefined;
        \\}
        \\if (!Reanimated?.useSharedValue) Reanimated = undefined;
        \\export { Reanimated };
    );
    try writeFile(tmp.dir, "consumer.ts",
        \\import { Reanimated } from 'react-native-gesture-handler/src/reanimatedWrapper';
        \\export function run() { return Reanimated.useEvent(); }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { useSharedValue } from 'react-native-reanimated';
        \\import { run } from './consumer';
        \\globalThis.shared = useSharedValue();
        \\globalThis.result = run();
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
    const hook_start = std.mem.indexOf(u8, result.output, "var exports_react_native_reanimated_src_hook_index").?;
    const hook_end = std.mem.indexOfPos(u8, result.output, hook_start, "//#endregion").?;
    const hook_output = result.output[hook_start..hook_end];
    try std.testing.expect(std.mem.indexOf(u8, hook_output, "useEvent:") != null);
    try std.testing.expect(std.mem.indexOf(u8, hook_output, "useSharedValue:") != null);
}

test "ESM re-export: local import alias getter uses source value in RN ESM wrap" {
    // react-native-svg 축소 재현:
    //   elements.ts: import Path from './Path'; export { Path };
    // RN ESM wrap 에서 elements.ts의 local import binding은 body에서 제거된다.
    // export getter가 현재 모듈의 rename(Path$1)을 반환하면 선언 없는 자유변수로 남고,
    // CJS consumer가 __toCommonJS(exports_elements)를 읽는 순간 ReferenceError가 난다.
    // getter는 source module의 실제 export value로 연결되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "Path.js",
        \\export default class Path {
        \\  static displayName = 'Path';
        \\}
    );
    try writeFile(tmp.dir, "elements.js",
        \\import Path from './Path.js';
        \\export { Path };
    );
    try writeFile(tmp.dir, "other.js",
        \\export class Path {
        \\  static displayName = 'OtherPath';
        \\}
    );
    try writeFile(tmp.dir, "consumer.cjs",
        \\const E = require('./elements.js');
        \\const Other = require('./other.js');
        \\globalThis.__zntcPathNames = [E.Path.displayName, Other.Path.displayName].join(',');
    );
    try writeFile(tmp.dir, "entry.js",
        \\require('./consumer.cjs');
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
    const elements_start = std.mem.indexOf(u8, result.output, "//#region elements.js").?;
    const elements_end = std.mem.indexOfPos(u8, result.output, elements_start, "//#endregion").?;
    const elements_output = result.output[elements_start..elements_end];
    try std.testing.expect(std.mem.indexOf(u8, elements_output, "Path: function() { return Path$") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_Path.default") != null);
}

test "ESM re-export: self re-export emits circular_reexport diagnostic (#1425 follow-up)" {
    // alias/resolver가 source를 자기 자신으로 redirect한 경우 (예: bungae alias 패턴)
    // emit 단계에서 자기 참조 getter가 생성되어 무한 재귀가 발생한다.
    // graph 빌드 단계에서 진단으로 거부 (rolldown CIRCULAR_REEXPORT).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "self.js",
        \\export { foo } from './self.js';
    );
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './self.js';
        \\console.log(Object.keys(ns));
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

    // self-cycle은 error로 거부
    try std.testing.expect(result.hasErrors());
    var found_diag = false;
    if (result.diagnostics) |diags| {
        for (diags) |d| {
            if (d.code == .circular_reexport) {
                found_diag = true;
                break;
            }
        }
    }
    try std.testing.expect(found_diag);
    // 출력에 자기 참조 getter가 만들어지지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return exports_self.foo") == null);
}

test "CJS: Flow export type alias + module.exports stays CJS (regression)" {
    // export type Foo = ... (type alias) + module.exports
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import lib from './mod.js';\nconsole.log(lib);");
    try writeFile(tmp.dir, "mod.js",
        \\import typeof Foo from './types.js';
        \\export type Bar = ReturnType<Foo>;
        \\module.exports = { value: 42 };
    );
    try writeFile(tmp.dir, "types.js", "export type Foo = string;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .flow = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
}

// Regression (mirrors react-native-gesture-handler's NativeRNGestureHandlerModule.ts):
// ESM-wrapped module does `import { Registry, Handle } from './lib.cjs'`, and a colliding
// top-level declaration elsewhere in the bundle forces the linker to hand `Registry` a
// canonical `$N` rename. The canonical-rename pass used to overwrite the CJS-in-ESM
// namespace rename (`__ns_N.Registry`), causing codegen to emit shorthand destructuring
// `({Registry,Handle}=require_lib())` into globals, leaving the module-local `Registry$N`
// undefined — `Registry$N.getEnforcing(...)` then throws at runtime.
//
// `early.ts` wins the name race (lowest exec_index) so spec.ts's imported bindings are
// the losers and get `$N` suffixes — the exact shape the original RN bundle hit.
test "CJS: ESM-wrapped named import from CJS — namespace rename must survive canonical rename (regression)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import Early from './early';
        \\import Spec from './spec';
        \\import Other from './other';
        \\console.log(Early, Spec, Other);
    );
    try writeFile(tmp.dir, "early.ts",
        \\const Registry = { kind: 'early-registry' };
        \\const Handle = { tag: 'early-handle' };
        \\export default { Registry: Registry, Handle: Handle };
    );
    try writeFile(tmp.dir, "spec.ts",
        \\import { Registry, Handle } from './lib.cjs';
        \\const _handle: Handle = { id: 0 };
        \\export default Registry.getEnforcing('Foo');
    );
    try writeFile(tmp.dir, "other.ts",
        \\const Registry = { kind: 'other-registry' };
        \\const Handle = { tag: 'other-handle' };
        \\export default { Registry: Registry, Handle: Handle };
    );
    try writeFile(tmp.dir, "lib.cjs",
        \\exports.Registry = { getEnforcing: function(n) { return { name: n }; } };
        \\exports.Handle = {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // BUG MARKER: body must not contain destructuring assignment that writes to
    //   GLOBAL `Registry`/`Handle` while the module-local vars are `Registry$N`/`Handle$N`.
    //   `({Registry,Handle}=require_lib())` leaves `Registry$1` undefined and
    //   `Registry$1.getEnforcing(...)` throws at runtime.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "({Registry,Handle}=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "({Registry, Handle}=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "({Registry}=") == null);

    // 올바른 형태: dev 모드 CJS named import는 별도 top-level var를 만들지 않고
    // HMR-safe registry lookup (`__zntc_modules["..."].fn()`) 의 property access 를 직접 참조한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"].fn().Registry.getEnforcing(") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Registry.getEnforcing(") != null);
}

test "CJS: ESM-wrapped named import from CJS barrel with getter re-exports stays direct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Stack } from './index.js';
        \\export default Stack.Screen;
    );
    try writeFile(tmp.dir, "index.js",
        \\var __createBinding = function(o, m, k, k2) {
        \\  if (k2 === undefined) k2 = k;
        \\  Object.defineProperty(o, k2, { enumerable: true, get: function() { return m[k]; } });
        \\};
        \\var __exportStar = function(m, exports) {
        \\  for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
        \\};
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\__exportStar(require("./exports.js"), exports);
    );
    try writeFile(tmp.dir, "exports.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.Stack = void 0;
        \\function Stack() {}
        \\Stack.Screen = function Screen() {};
        \\exports.Stack = Stack;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // dev 모드 CJS named import 는 HMR-safe `__zntc_modules["..."].fn().Stack.Screen` 형태.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"].fn().Stack.Screen") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Stack = require_index().Stack;") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Stack = __zntc_modules[") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_index()).Stack") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "({Stack}") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__ns_") == null);
}

test "CJS: ESM-wrapped default import from CJS gets preamble assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import value from './lib.cjs';
        \\export default value;
    );
    try writeFile(tmp.dir, "lib.cjs", "module.exports = function value() { return 1; };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // dev 모드 ESM-wrapped default import 는 `value = __zntc_modules["..."].fn();` 형태.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value = __zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"].fn();") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value = __toESM(require_lib()).default;") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "({value}") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value;") != null);
}

test "ESM export star: empty CJS-like type barrel does not shadow later star export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createNavigatorFactory } from './native.js';
        \\console.log(createNavigatorFactory());
    );
    try writeFile(tmp.dir, "native.js",
        \\export * from './types.js';
        \\export * from './core.js';
    );
    try writeFile(tmp.dir, "types.js", "export {};");
    try writeFile(tmp.dir, "core.js",
        \\export function createNavigatorFactory() {
        \\  return 'ok';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createNavigatorFactory()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_types().createNavigatorFactory") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createNavigatorFactory = require_types().createNavigatorFactory") == null);
}

// #1754: namespace import 가 member access (ns.prop) 로 먼저 수집된 후
// bare reference (ns 자체를 값으로) 로 opaque 전환될 때, opaque 경로에서
// `access.members.deinit` 만 호출하여 이전에 append 된 ArrayList 의 backing
// buffer 가 leak. GPA debug allocator 가 leak 검출하므로 이 테스트 자체가 regression.
test "ESM ns-access: opaque path (bare ref after member access) doesn't leak" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.js",
        \\export function greet() { return 'hi'; }
        \\export function wave() { return 'wave'; }
        \\export const tag = 'tag';
    );
    try writeFile(tmp.dir, "entry.js",
        \\import * as utils from './utils.js';
        \\// 먼저 member access 여러 번 (access.members 에 append 됨)
        \\console.log(utils.greet(), utils.wave(), utils.tag);
        \\// 이어서 bare reference (opaque 로 전환 → 이전 ArrayList 들 해제되어야)
        \\const all = utils;
        \\console.log(Object.keys(all).length);
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 실제 검증은 GPA debug allocator 의 leak 검출에 위임 —
    // leak 발생 시 `zig build test` 가 테스트 실패 처리.
}

test "ESM wrapped static import under strict order does not emit raw require" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("node_modules/@tanstack/react-query/build/modern");
    try tmp.dir.makePath("node_modules/@tanstack/query-core/build/modern");
    try writeFile(tmp.dir, "entry.js",
        \\import { useQueries } from '@tanstack/react-query';
        \\console.log(useQueries());
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/package.json",
        \\{
        \\  "name": "@tanstack/react-query",
        \\  "type": "module",
        \\  "main": "build/legacy/index.cjs",
        \\  "module": "build/legacy/index.js",
        \\  "exports": {
        \\    ".": {
        \\      "import": { "default": "./build/modern/index.js" },
        \\      "require": { "default": "./build/modern/index.cjs" }
        \\    }
        \\  },
        \\  "sideEffects": false
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/query-core/package.json",
        \\{
        \\  "name": "@tanstack/query-core",
        \\  "type": "module",
        \\  "exports": {
        \\    ".": { "import": { "default": "./build/modern/index.js" } }
        \\  },
        \\  "sideEffects": false
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/query-core/build/modern/index.js",
        \\export const core = 'core';
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/types.js",
        \\export {};
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/index.js",
        \\export * from "@tanstack/query-core";
        \\export * from "./types.js";
        \\import { useQueries } from './useQueries.js';
        \\import { queryOptions } from './queryOptions.js';
        \\export { useQueries, queryOptions };
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/useQueries.js",
        \\export function useQueries() {
        \\  return 'queries';
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/queryOptions.js",
        \\export function queryOptions() {
        \\  return 'options';
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "queries") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./useQueries.js\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./queryOptions.js\")") == null);
}

test "ESM wrapped barrel namespace import under strict order does not emit raw require" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("node_modules/@tanstack/react-query/build/modern");
    try tmp.dir.makePath("node_modules/@tanstack/query-core/build/modern");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ReactQuery from '@tanstack/react-query';
        \\console.log(ReactQuery.useQueries(), ReactQuery.QueryClientProvider());
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/package.json",
        \\{
        \\  "name": "@tanstack/react-query",
        \\  "type": "module",
        \\  "main": "build/legacy/index.cjs",
        \\  "module": "build/legacy/index.js",
        \\  "exports": {
        \\    ".": {
        \\      "import": { "default": "./build/modern/index.js" },
        \\      "require": { "default": "./build/modern/index.cjs" }
        \\    }
        \\  },
        \\  "sideEffects": false
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/query-core/package.json",
        \\{
        \\  "name": "@tanstack/query-core",
        \\  "type": "module",
        \\  "exports": {
        \\    ".": { "import": { "default": "./build/modern/index.js" } }
        \\  },
        \\  "sideEffects": false
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/query-core/build/modern/index.js",
        \\export const QueryClient = 'core-client';
        \\export const skipToken = 'skip-token';
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/types.js",
        \\export {};
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/index.js",
        \\export * from "@tanstack/query-core";
        \\export * from "./types.js";
        \\import { useQueries } from './useQueries.js';
        \\import { useQuery } from './useQuery.js';
        \\import { useMutation } from './useMutation.js';
        \\import { QueryClientProvider, useQueryClient } from './QueryClientProvider.js';
        \\import { HydrationBoundary } from './HydrationBoundary.js';
        \\import { QueryErrorResetBoundary, useQueryErrorResetBoundary } from './QueryErrorResetBoundary.js';
        \\export {
        \\  useQueries,
        \\  useQuery,
        \\  useMutation,
        \\  QueryClientProvider,
        \\  useQueryClient,
        \\  HydrationBoundary,
        \\  QueryErrorResetBoundary,
        \\  useQueryErrorResetBoundary,
        \\};
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/useQueries.js",
        \\export function useQueries() {
        \\  return 'queries';
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/useQuery.js",
        \\export function useQuery() {
        \\  return 'query';
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/useMutation.js",
        \\export function useMutation() {
        \\  return 'mutation';
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/QueryClientProvider.js",
        \\export function QueryClientProvider() {
        \\  return 'provider';
        \\}
        \\export function useQueryClient() {
        \\  return 'client';
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/HydrationBoundary.js",
        \\export function HydrationBoundary() {
        \\  return 'hydration';
        \\}
    );
    try writeFile(tmp.dir, "node_modules/@tanstack/react-query/build/modern/QueryErrorResetBoundary.js",
        \\export function QueryErrorResetBoundary() {
        \\  return 'boundary';
        \\}
        \\export function useQueryErrorResetBoundary() {
        \\  return 'reset';
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "queries") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./useQueries.js\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"./QueryClientProvider.js\")") == null);
}

test "ESM wrap: RN non-inlined CJS named import is deconflicted with wrapped locals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("node_modules/react");
    try writeFile(tmp.dir, "node_modules/react/package.json",
        \\{
        \\  "name": "react",
        \\  "main": "index.js"
        \\}
    );
    try writeFile(tmp.dir, "node_modules/react/index.js",
        \\exports.useEffect = function useEffect(value) {
        \\  return 'effect:' + value;
        \\};
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { runOverlay } from './overlay.js';
        \\import { touch } from './api.js';
        \\console.log(typeof touch, runOverlay('ok'));
    );
    try writeFile(tmp.dir, "overlay.js",
        \\import { useEffect as Q } from 'react';
        \\export function runOverlay(value) {
        \\  return Q(value);
        \\}
    );
    try writeFile(tmp.dir, "api.js",
        \\var Q = class InterceptorPlugin {};
        \\export const touch = Q;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .dev_mode = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "useEffect") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Q$") != null);
}

// ============================================================
// `.cjs` / `.cts` 는 Node CommonJS 컨벤션상 ESM 구문 (`import`/`export`) 거부.
// 이전엔 graph/parser_setup.zig 가 모든 모듈을 is_module=true 로 promote 해서
// `.cjs` 도 `export const x = 1` 을 받아들여 Node 와 호환 안 됐음.
// ============================================================

test "CJS convention: `.cjs` 가 top-level `export const` 를 거부" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs",
        \\export const x = 1;
    );

    const entry = try absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
}

test "CJS convention: `.cjs` 의 `module.exports` + `with` 모두 정상 (script mode)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs",
        \\function run(obj) {
        \\  var x = 1;
        \\  with (obj) { console.log(x); }
        \\}
        \\module.exports = { run };
    );

    const entry = try absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "CJS convention: `.cts` 는 ESM 구문 허용 (TS 가 module.exports 로 transpile — tsc 정책)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.cts';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.cts", "export const x: number = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}
