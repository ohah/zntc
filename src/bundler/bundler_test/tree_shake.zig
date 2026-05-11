const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking integration tests
// ============================================================

test {
    _ = @import("tree_shake/annotations.zig");
    _ = @import("tree_shake/side_effects.zig");
    _ = @import("tree_shake/integration_barrels.zig");
    _ = @import("tree_shake/cjs.zig");
    _ = @import("tree_shake/inner_graph.zig");
    _ = @import("tree_shake/lazy_barrel.zig");
    _ = @import("tree_shake/edge_cases.zig");
    _ = @import("tree_shake/re_exports.zig");
    _ = @import("tree_shake/writers.zig");
    _ = @import("tree_shake/dead_statements.zig");
    _ = @import("tree_shake/rn_esm_wrap.zig");
}

test "TreeShaking: unused side_effects=false module excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts imports only b. c.ts is imported by b but side_effects=false + nobody uses c's exports.
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");
    try writeFile(tmp.dir, "c.ts", "export const dead_code = 'should not appear';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // Bundler를 직접 사용하면 c.ts는 graph에 없음 (a.ts가 import하지 않으므로).
    // tree-shaking은 graph에 있는데 아무도 사용하지 않는 모듈을 제거.
    // 실제 테스트: b.ts가 c.ts를 import하지만 c.ts의 export를 사용하지 않는 경우.
    try writeFile(tmp.dir, "b.ts", "import './c';\nexport const x = 42;");

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // x는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // c.ts는 pure code만 있으므로 auto-pure 감지로 side_effects=false → 제외됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_code") == null);
}

test "TreeShaking: tree_shaking=false preserves all modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1;") != null);
}

test "TreeShaking: entry point exports preserved in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const a = 1;\nexport const b = 2;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 진입점의 모든 export가 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

test "TreeShaking: only used exports from dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { used } from './b'; console.log(used);");
    try writeFile(tmp.dir, "b.ts", "export const used = 'yes'; export const unused = 'no';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // used는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
    // unused는 statement-level tree-shaking으로 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no\"") == null);
}

test "TreeShaking: re-export chain dependency included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "TreeShaking: side-effect-only import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './polyfill';\nconst x = 1;");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.myPolyfill = true;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill.ts는 side_effects=true (기본) → 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "myPolyfill") != null);
}

test "TreeShaking: side-effect-only CJS import emits require call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import './cjs.js';\nconsole.log('entry');");
    try writeFile(tmp.dir, "cjs.js", "module.exports = {}; globalThis.cjsSideEffectImport = true;");

    const entry = try absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cjsSideEffectImport") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjs();") != null);
}

test "TreeShaking: runBeforeMain import-only root preserves side-effect dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log('entry');");
    try writeFile(tmp.dir, "prelude.ts", "import './polyfill';");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.runBeforeMainPolyfill = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const prelude = try absPath(&tmp, "prelude.ts");
    defer std.testing.allocator.free(prelude);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .run_before_main = &.{prelude},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "runBeforeMainPolyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_prelude") != null);
}

test "TreeShaking: class extends call expression preserved (#1261 edge)" {
    // class Foo extends getBase() — extends call은 side-effect이므로 보존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function getBase() { console.log("EXTENDS_CALL_MARKER"); return class {}; }
        \\export class Unused extends getBase() {}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXTENDS_CALL_MARKER") != null);
}

test "#1291 실제 증상: \"use strict\" + non-simple params 있는 모듈이 graph에서 스킵됨" {
    // 실제 이슈 재현: backend.js 같은 webpack UMD 번들이 내부 함수에
    // `"use strict"` + destructuring params 조합을 가질 때 parser가 validation 에러를
    // 내고 graph.zig가 모듈 전체를 스킵 → require 참조가 생기지만 정의는 없음.
    //
    // SyntaxError지만 V8/Hermes 런타임은 실행하므로 번들러는 경고로 처리해야 함
    // (esbuild/rollup 동일 정책).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\function foo({ a, b }) {
        \\    "use strict";
        \\    return a + b;
        \\}
        \\module.exports = foo;
    );
    try writeFile(tmp.dir, "entry.js",
        \\const foo = require('./lib.js');
        \\console.log(foo({ a: 1, b: 2 }));
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib = __commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = foo") != null);
}

// kysely 회귀 #2052: TS interface-only 가 strip 후 빈 `export {}` 만 남고, post-transform
// AST 에서 transformer 가 그 marker 까지 drop 하면 refresh 가 exports_kind 를 `.none` 으로
// 강등 → markEsmCjsHybrid Pass 2 가 implicit CJS 로 승격 → resolveOrCjsFallback 이 첫 번째
// `export *` source 의 빈 CJS wrapper 를 모든 named import 의 source 로 stick 시킴 →
// 실제 정의가 있는 다음 `export *` 는 walk 안 되어 dummy-driver.js 가 tree-shake 된다.
test "TreeShaking: export * chain through TS-stripped empty source still resolves named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Bar } from './barrel';
        \\console.log(new Bar().tag());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './empty';
        \\export * from './real';
    );
    try writeFile(tmp.dir, "empty.ts",
        \\export {};
    );
    try writeFile(tmp.dir, "real.ts",
        \\export class Bar {
        \\  tag() { return 'EXPORT_STAR_CHAIN_KEPT'; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXPORT_STAR_CHAIN_KEPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Bar") != null);
}

// cheerio 회귀 #2051: namespace import (`import * as ns from 'cjslib'`) 의 모든 소비자가
// tree-shake 로 사라졌는데 ImportBinding 자체는 살아 있어 linker 가 `var ns =
// __toESM(require_X(), 1)` 를 emit. 그러나 해당 CJS wrapper 는 모듈 미포함이라 정의되지
// 않아 `require_X is not defined` ReferenceError. preamble emit 도 같이 drop 해야 한다.
test "TreeShaking: namespace import preamble dropped when target excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used());
    );
    // lib.js 가 namespace 로 cjslib 을 import 하지만, 소비자 (`heavy`) 는 entry 에서 안 쓴다.
    try writeFile(tmp.dir, "lib.js",
        \\import * as cjslib from './cjslib.cjs';
        \\export function used() { return 'NS_TARGET_DROP_USED'; }
        \\export function heavy() { return cjslib.bar(); }
    );
    try writeFile(tmp.dir, "cjslib.cjs",
        \\'use strict';
        \\exports.bar = function() { return 'NS_TARGET_DROP_HEAVY'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_USED") != null);
    // heavy() 는 사용 안 하므로 cjslib + 본문 모두 prune 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_HEAVY") == null);
    // `var X = __toESM(require_cjslib_cjs(), 1)` 같은 orphan preamble 이 남으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjslib") == null);
}

test "TreeShaking: CJS default import member access seeds only used export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './react-like.cjs';
        \\console.log(React.createElement());
    );
    try writeFile(tmp.dir, "react-like.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_MEMBER_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_MEMBER_UNUSED'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_MEMBER_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_MEMBER_UNUSED") == null);
}

test "TreeShaking: CJS default import value escape keeps all exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './react-like.cjs';
        \\console.log(typeof React);
    );
    try writeFile(tmp.dir, "react-like.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_ESCAPE_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_ESCAPE_KEPT'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_ESCAPE_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_ESCAPE_KEPT") != null);
}

test "TreeShaking: CJS default member access follows module.exports require proxy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './index.cjs';
        \\console.log(React.createElement());
    );
    try writeFile(tmp.dir, "index.cjs",
        \\'use strict';
        \\{
        \\  module.exports = require('./react-production.cjs');
        \\}
    );
    try writeFile(tmp.dir, "react-production.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_PROXY_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_PROXY_UNUSED'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_PROXY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_PROXY_UNUSED") == null);
}
