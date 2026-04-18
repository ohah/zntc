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
    // minified 런타임 헬퍼
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS=") != null);
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

test "CJS: __toESM wraps default import from CJS" {
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
    // default import는 __toESM으로 래핑되어야 함
    // .ts importer → Babel 모드 (isNodeMode 없음)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM(require_lib())") != null);
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
    for (graph.modules.items) |m| {
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
    try writeFile(tmp.dir, "lib.cjs", "module.exports = 42;");

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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS0002]") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS0002]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS0002]") == null);
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

    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS0002] Top-level await requires ESM output format.") != null);
    // 중복 경고 방지: 정확히 한 번만 emit되어야 함 (이전엔 iife/umd/amd prologue가 추가로 emit했음)
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.output, "[ZTS0002]"));
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS0002]") == null);
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

    try std.testing.expect(std.mem.indexOf(u8, result.output, "[ZTS0002]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS0002") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS0002") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS0002") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ZTS0002") != null);
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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
    for (graph.modules.items) |m| {
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
