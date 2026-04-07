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
// P1: package.json exports field (통합)
// ============================================================

test "PackageJson: exports string shorthand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { hello } from 'mypkg';\nconsole.log(hello);");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{ "name": "mypkg", "exports": "./src/index.js" }
    );
    try writeFile(tmp.dir, "node_modules/mypkg/src/index.js", "export const hello = 'from-exports';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-exports\"") != null);
}

test "PackageJson: exports condition import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from 'condpkg';\nconsole.log(val);");
    try writeFile(tmp.dir, "node_modules/condpkg/package.json",
        \\{ "name": "condpkg", "exports": { ".": { "import": "./esm.js", "require": "./cjs.js" } } }
    );
    try writeFile(tmp.dir, "node_modules/condpkg/esm.js", "export const val = 'esm-path';");
    try writeFile(tmp.dir, "node_modules/condpkg/cjs.js", "module.exports = { val: 'cjs-path' };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"esm-path\"") != null);
}

test "PackageJson: subpath exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Button } from 'ui-lib/Button';\nconsole.log(Button);");
    try writeFile(tmp.dir, "node_modules/ui-lib/package.json",
        \\{ "name": "ui-lib", "exports": { "./Button": "./src/Button.js" } }
    );
    try writeFile(tmp.dir, "node_modules/ui-lib/src/Button.js", "export const Button = 'btn-component';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"btn-component\"") != null);
}

test "PackageJson: wildcard exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from 'wpkg/utils';\nconsole.log(foo);");
    try writeFile(tmp.dir, "node_modules/wpkg/package.json",
        \\{ "name": "wpkg", "exports": { "./*": "./src/*.js" } }
    );
    try writeFile(tmp.dir, "node_modules/wpkg/src/utils.js", "export const foo = 'wildcard-resolved';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"wildcard-resolved\"") != null);
}

// ============================================================
// P1: package.json module vs main field
// ============================================================

test "PackageJson: module field preferred over main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from 'dualpkg';\nconsole.log(x);");
    try writeFile(tmp.dir, "node_modules/dualpkg/package.json",
        \\{ "name": "dualpkg", "main": "./cjs.js", "module": "./esm.js" }
    );
    try writeFile(tmp.dir, "node_modules/dualpkg/esm.js", "export const x = 'from-module-field';");
    try writeFile(tmp.dir, "node_modules/dualpkg/cjs.js", "exports.x = 'from-main-field';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-module-field\"") != null);
}

test "PackageJson: main field fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { y } from 'mainonly';\nconsole.log(y);");
    try writeFile(tmp.dir, "node_modules/mainonly/package.json",
        \\{ "name": "mainonly", "main": "./lib.js" }
    );
    try writeFile(tmp.dir, "node_modules/mainonly/lib.js", "export const y = 'from-main';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-main\"") != null);
}

test "PackageJson: no package.json index.js fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { z } from 'nopkg';\nconsole.log(z);");
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "export const z = 'index-fallback';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"index-fallback\"") != null);
}

// ============================================================
// P1: .mjs/.mts/.cjs/.cts extension handling
// ============================================================

test "Extension: import .mts file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.mjs';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.mts", "export const x = 'from-mts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-mts\"") != null);
}

test "Extension: import .cts file via .cjs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.cjs';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.cts", "export const x = 'from-cts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-cts\"") != null);
}

test "Extension: direct .mts import without .mjs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './util';\nconsole.log(val);");
    try writeFile(tmp.dir, "util.mts", "export const val = 'mts-direct';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"mts-direct\"") != null);
}

// ============================================================
// P1: Dynamic import() output
// ============================================================

test "DynamicImport: static path in import()" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lazy = import('./lazy');
        \\lazy.then(m => console.log(m));
    );
    try writeFile(tmp.dir, "lazy.ts", "export const data = 'lazy-loaded';\nconsole.log(data);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 단일 번들 모드에서 lazy 모듈 코드가 포함되어야 함
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"lazy-loaded\"") != null);
}

test "DynamicImport: external dynamic import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const ext = import('external-pkg');
        \\ext.then(console.log);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-pkg"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "DynamicImport: combined with static import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './shared';
        \\const lazy = import('./shared');
        \\console.log(x);
        \\lazy.then(m => console.log(m));
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared-val';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shared-val\"") != null);
}

// ============================================================
// P1: CJS/IIFE format exports with scope hoisting
// ============================================================

test "Format: CJS scope_hoist entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\export const result = helper();
        \\export function getResult() { return result; }
    );
    try writeFile(tmp.dir, "helper.ts", "export function helper() { return 42; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

test "Format: IIFE scope_hoist entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './dep';
        \\export const doubled = value * 2;
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 21;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value * 2") != null);
}

// ============================================================
// P2: export default anonymous expression
// ============================================================

// "Default: anonymous object default export imported" — 기존 "Default: default export object literal"과 중복으로 제거

test "Default: anonymous string default export imported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import greeting from './greeting';
        \\console.log(greeting);
    );
    try writeFile(tmp.dir, "greeting.ts", "export default 'hello world';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello world\"") != null);
}

// ============================================================
// P2: export { X as default }
// ============================================================

test "Default: export named as default then import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import def from './mod';
        \\console.log(def);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const X = 'named-as-default';
        \\export { X as default };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named-as-default\"") != null);
}

// ============================================================
// P2: namespace import (import * as ns)
// ============================================================

test "Namespace: import * as ns usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as utils from './utils';
        \\console.log(utils.add(1, 2), utils.sub(3, 1));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function add(a: number, b: number) { return a + b; }
        \\export function sub(a: number, b: number) { return a - b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function sub") != null);
}

test "Namespace: import * combined with named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as math from './math';
        \\import { PI } from './math';
        \\console.log(math.add(1, 2), PI);
    );
    try writeFile(tmp.dir, "math.ts",
        \\export const PI = 3.14;
        \\export function add(a: number, b: number) { return a + b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "3.14") != null);
}

// ============================================================
// P2: scoped packages (@scope/pkg)
// ============================================================

test "Resolution: scoped package @scope/pkg" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { thing } from '@myorg/utils';\nconsole.log(thing);");
    try writeFile(tmp.dir, "node_modules/@myorg/utils/package.json",
        \\{ "name": "@myorg/utils", "main": "./index.js" }
    );
    try writeFile(tmp.dir, "node_modules/@myorg/utils/index.js", "export const thing = 'scoped-pkg';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scoped-pkg\"") != null);
}

// ============================================================
// P2: JSON import
// ============================================================

test "Resolution: JSON file import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{ "name": "test", "version": "1.0.0" }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // JSON import는 에러 없이 번들 생성 (내용 포함 여부는 구현에 따라)
    try std.testing.expect(!result.hasErrors());
}

test "JSON import: ESM format uses scope-hoisted var (linker integration)" {
    // linker 포함 통합 테스트: ESM 포맷에서 JSON → ESM AST로 변환되어
    // export default → var 할당 형태로 출력되는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './data.json';\nconsole.log(data.key);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value"}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // JSON ESM: named export 변수로 출력, __commonJS 래핑 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
}

test "JSON import: named exports from top-level object keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { name, version } from './app.json';\nconsole.log(name, version);");
    try writeFile(tmp.dir, "app.json",
        \\{"name":"ExampleApp","version":1}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // named export 변수가 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ExampleApp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(name") != null);
}

test "JSON import: named exports + default export coexist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config, { name } from './config.json';
        \\console.log(name, config);
    );
    try writeFile(tmp.dir, "config.json",
        \\{"name":"test","debug":true}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"test\"") != null);
}

test "JSON import: non-object JSON has no named exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import arr from './data.json';\nconsole.log(arr);");
    try writeFile(tmp.dir, "data.json", "[1, 2, 3]");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "IIFE globalName: export → return 변환 (linker integration)" {
    // IIFE + globalName에서 엔트리 export가 "return { ... }" 형태로 출력되는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const answer = 42;\nexport const name = \"test\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .global_name = "MyLib",
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // IIFE prologue: var MyLib = (function() {
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var MyLib = (function()") != null);
    // 엔트리 export가 return으로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return {") != null);
    // export 키워드가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export {") == null);
}

// ============================================================
// P2: multi-level rename re-export chain
// ============================================================

// "Re-export: three-level rename chain" — 기존 "Re-export: rename chain (A→B→C→D)"와 중복으로 제거

// ============================================================
// P3: nested scope conflict avoidance
// ============================================================

test "Deconflict: rename avoids nested scope variable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈이 'x'를 top-level에 가짐 → 리네임 발생
    // entry에는 함수 안에 'x$1'이 있음 → 리네임이 x$1을 피해야 함
    try writeFile(tmp.dir, "entry.ts",
        \\import './other';
        \\const x = 'entry-x';
        \\function inner() { const x$1 = 'nested'; return x$1; }
        \\console.log(x, inner());
    );
    try writeFile(tmp.dir, "other.ts", "const x = 'other-x';\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"entry-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"other-x\"") != null);
}

// ============================================================
// P3: long re-export chain (10 levels)
// ============================================================

test "Re-export: 10-level chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './r1';\nconsole.log(val);");
    try writeFile(tmp.dir, "r1.ts", "export { val } from './r2';");
    try writeFile(tmp.dir, "r2.ts", "export { val } from './r3';");
    try writeFile(tmp.dir, "r3.ts", "export { val } from './r4';");
    try writeFile(tmp.dir, "r4.ts", "export { val } from './r5';");
    try writeFile(tmp.dir, "r5.ts", "export { val } from './r6';");
    try writeFile(tmp.dir, "r6.ts", "export { val } from './r7';");
    try writeFile(tmp.dir, "r7.ts", "export { val } from './r8';");
    try writeFile(tmp.dir, "r8.ts", "export { val } from './r9';");
    try writeFile(tmp.dir, "r9.ts", "export { val } from './r10';");
    try writeFile(tmp.dir, "r10.ts", "export const val = 'deep-10';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep-10\"") != null);
}

// ============================================================
// P3: multi-entry + scope hoist + name conflicts
// ============================================================

test "MultiEntry: scope hoist with shared dep name conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts",
        \\import { shared } from './shared';
        \\const name = 'e1';
        \\console.log(name, shared);
    );
    try writeFile(tmp.dir, "e2.ts",
        \\import { shared } from './shared';
        \\const name = 'e2';
        \\console.log(name, shared);
    );
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';\nconst name = 'shared';");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 모듈의 'name' 충돌 → 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "name$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"common\"") != null);
}

// ============================================================
// P3: empty export {} with scope hoist
// ============================================================

test "Export: empty export {} stripped in scope hoist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './sideeffect';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "sideeffect.ts",
        \\console.log('side');
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"side\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"main\"") != null);
    // export {} 가 번들에 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export {}") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export{}") == null);
}

// ============================================================
// P3: import type full strip verification
// ============================================================

test "TypeScript: import type fully stripped in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type User } from './types';
        \\import { greet } from './greet';
        \\const u: User = { name: 'Alice' };
        \\console.log(greet(u.name));
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface User { name: string; }
        \\export interface Post { title: string; }
    );
    try writeFile(tmp.dir, "greet.ts", "export function greet(name: string) { return 'Hello ' + name; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // interface 완전 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    // greet 함수는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
}

