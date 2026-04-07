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
// Rollup-style tests: re-export variants + scope hoisting
// ============================================================

test "Rollup: export * with local override" {
    // Rollup form/samples 참고: star re-export + 로컬 같은 이름 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y } from './barrel';
        \\console.log(x, y);
    );
    // barrel에서 export * 하면서 x를 로컬로도 export
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './source';
        \\export const x = 'overridden';
    );
    try writeFile(tmp.dir, "source.ts",
        \\export const x = 'original';
        \\export const y = 'from-source';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-source\"") != null);
}

test "Rollup: chained re-exports through three modules" {
    // Rollup 스타일: A imports from B, B re-exports from C, C re-exports from D
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { deep } from './l1';\nconsole.log(deep);");
    try writeFile(tmp.dir, "l1.ts", "export { deep } from './l2';");
    try writeFile(tmp.dir, "l2.ts", "export { deep } from './l3';");
    try writeFile(tmp.dir, "l3.ts", "export const deep = 'leaf-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"leaf-value\"") != null);
    // 중간 re-export 모듈들의 import/export는 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

test "Rollup: side-effect free import ordering" {
    // Rollup: import 순서가 실행 순서를 결정 (ESM spec)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './polyfill';
        \\import './setup';
        \\import { app } from './app';
        \\console.log(app);
    );
    try writeFile(tmp.dir, "polyfill.ts", "console.log('polyfill');");
    try writeFile(tmp.dir, "setup.ts", "console.log('setup');");
    try writeFile(tmp.dir, "app.ts", "export const app = 'ready';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill → setup → app → entry 순서
    const poly_pos = std.mem.indexOf(u8, result.output, "\"polyfill\"") orelse return error.TestUnexpectedResult;
    const setup_pos = std.mem.indexOf(u8, result.output, "\"setup\"") orelse return error.TestUnexpectedResult;
    const app_pos = std.mem.indexOf(u8, result.output, "\"ready\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(poly_pos < setup_pos);
    try std.testing.expect(setup_pos < app_pos);
}

test "Rollup: multiple exports from single module" {
    // Rollup form/samples: 한 모듈에서 여러 종류의 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn, cls, val, arrow } from './lib';
        \\console.log(fn(), new cls(), val, arrow());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function fn() { return 1; }
        \\export class cls { x = 2; }
        \\export const val = 3;
        \\export const arrow = () => 4;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class cls") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "val = 3") != null);
}

// ============================================================
// esbuild-style tests: external handling + format conversion
// ============================================================

test "esbuild: external glob pattern" {
    // esbuild: 글롭 패턴으로 external 지정
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import ReactDOM from 'react-dom';
        \\import { local } from './local';
        \\console.log(local);
    );
    try writeFile(tmp.dir, "local.ts", "export const local = 'bundled';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react*"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // react, react-dom 둘 다 external
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"bundled\"") != null);
}

test "esbuild: node builtins auto-external" {
    // esbuild: platform=node에서 node: prefix 자동 external
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import crypto from 'node:crypto';
        \\import { readFile } from 'node:fs/promises';
        \\const key = 'local-value';
        \\console.log(key);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local-value\"") != null);
}

test "esbuild: define global replacement" {
    // esbuild --define 테스트는 CLI 수준 → 번들러에서는 변환 결과만 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const isProd = false;
        \\if (isProd) { console.log('prod'); }
        \\console.log('dev');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"dev\"") != null);
}

test "esbuild: ESM to CJS format conversion with imports" {
    // esbuild: ESM 입력 → CJS 출력, import가 require로 변환되지 않고 번들에 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\export const result = helper(42);
    );
    try writeFile(tmp.dir, "helper.ts",
        \\export function helper(n: number) { return n * 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

test "esbuild: ESM to IIFE with scope hoisting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add } from './math';
        \\console.log(add(1, 2));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export function add(a: number, b: number) { return a + b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function add") != null);
    // import 문 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

// ============================================================
// Bun-style tests: TypeScript, barrel files, resolution
// ============================================================

test "Bun: barrel file with selective import" {
    // Bun: barrel에서 일부만 import (사용하지 않는 export도 번들에는 포함)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Button } from './components';
        \\console.log(Button);
    );
    try writeFile(tmp.dir, "components/index.ts",
        \\export { Button } from './Button';
        \\export { Card } from './Card';
    );
    try writeFile(tmp.dir, "components/Button.ts", "export const Button = 'btn';");
    try writeFile(tmp.dir, "components/Card.ts", "export const Card = 'card';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"btn\"") != null);
}

test "Bun: TypeScript interface-only module" {
    // Bun: 타입만 있는 모듈 import
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MyType } from './types';
        \\const x: MyType = 42;
        \\console.log(x);
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface MyType {}
        \\export type OtherType = string | number;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 인터페이스/타입 모두 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Bun: .tsx file bundling" {
    // Bun: TSX 파일의 JSX 변환 + 번들링
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\import { Component } from './comp';
        \\console.log(Component);
    );
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Component() { return <div>hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Component") != null);
    // JSX가 변환됨 (<div> → React.createElement 등)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<div>") == null);
}

test "Bun: extension resolution priority (.ts over .js)" {
    // Bun: .ts 확장자가 .js보다 우선
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 'from-ts';");
    try writeFile(tmp.dir, "lib.js", "export const x = 'from-js';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // .ts가 .js보다 우선
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-ts\"") != null);
}

test "Bun: complex real-world component pattern" {
    // Bun 스타일: 컴포넌트 + 훅 + 유틸 패턴 (React-like)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { createStore } from './store';
        \\import { logger } from './utils/logger';
        \\const store = createStore();
        \\logger('App initialized');
        \\console.log(store);
    );
    try writeFile(tmp.dir, "store.ts",
        \\import { logger } from './utils/logger';
        \\export function createStore() {
        \\  logger('Store created');
        \\  return { state: {} };
        \\}
    );
    try writeFile(tmp.dir, "utils/logger.ts",
        \\export function logger(msg: string) {
        \\  console.log('[LOG]', msg);
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // logger가 store보다 먼저 (의존성 순서)
    const logger_pos = std.mem.indexOf(u8, result.output, "function logger") orelse return error.TestUnexpectedResult;
    const store_pos = std.mem.indexOf(u8, result.output, "function createStore") orelse return error.TestUnexpectedResult;
    try std.testing.expect(logger_pos < store_pos);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
}

// ============================================================
// Rolldown-style tests: CJS compat + symbol deconflicting
// ============================================================

test "Rolldown: symbol deconflicting with many modules" {
    // Rolldown: 5개 모듈에서 같은 이름 사용 → 순차적 $1, $2, ...
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\import './b';
        \\import './c';
        \\import './d';
        \\const value = 'entry';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "a.ts", "const value = 'a';\nconsole.log(value);");
    try writeFile(tmp.dir, "b.ts", "const value = 'b';\nconsole.log(value);");
    try writeFile(tmp.dir, "c.ts", "const value = 'c';\nconsole.log(value);");
    try writeFile(tmp.dir, "d.ts", "const value = 'd';\nconsole.log(value);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 5개 value → 최소 4개는 리네임 ($1, $2, $3, $4)
    var rename_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "value$")) |pos| {
        rename_count += 1;
        search_from = pos + 1;
    }
    try std.testing.expect(rename_count >= 4);
}

test "Rolldown: export default function with rename" {
    // Rolldown: default export 함수 + 같은 이름의 변수가 다른 모듈에
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import handler from './handler';
        \\const handler2 = () => 'local';
        \\console.log(handler(), handler2());
    );
    try writeFile(tmp.dir, "handler.ts",
        \\export default function handler() { return 'from-module'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local\"") != null);
}

test "Rolldown: deep re-export with export *" {
    // Rolldown tree_shaking: export * 체인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { data } from './index';
        \\console.log(data);
    );
    try writeFile(tmp.dir, "index.ts", "export * from './layer1';");
    try writeFile(tmp.dir, "layer1.ts", "export * from './layer2';");
    try writeFile(tmp.dir, "layer2.ts", "export const data = 'deep-star';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep-star\"") != null);
}

test "Rolldown: mixed default and named imports from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config, { VERSION, DEBUG } from './config';
        \\console.log(config, VERSION, DEBUG);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export const VERSION = '2.0';
        \\export const DEBUG = false;
        \\export default { name: 'myapp' };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"myapp\"") != null);
}

// ============================================================
// Webpack-style tests: scope hoisting edge cases
// ============================================================

test "Webpack: scope hoisting with nested functions" {
    // Webpack scope-hoisting: 중첩 함수의 변수는 충돌 대상 아님
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { outer } from './mod';
        \\console.log(outer());
    );
    try writeFile(tmp.dir, "mod.ts",
        \\export function outer() {
        \\  const x = 1;
        \\  function inner() { const x = 2; return x; }
        \\  return x + inner();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function inner") != null);
}

test "Webpack: import order matches dependency graph" {
    // Webpack cases/scope-hoisting: import-order
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './a';
        \\import { b } from './b';
        \\console.log(a + b);
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { shared } from './shared';
        \\export const a = shared + '-a';
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { shared } from './shared';
        \\export const b = shared + '-b';
    );
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'base';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared → a → b → entry 순서 (shared가 가장 먼저)
    const shared_pos = std.mem.indexOf(u8, result.output, "\"base\"") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "\"-a\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shared_pos < a_pos);
}

test "Webpack: re-export with alias name" {
    // Webpack: export { x as y } from
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { aliased } from './reexport';
        \\console.log(aliased);
    );
    try writeFile(tmp.dir, "reexport.ts", "export { original as aliased } from './source';");
    try writeFile(tmp.dir, "source.ts", "export const original = 'orig-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"orig-value\"") != null);
}

// ============================================================
// Stress / robustness tests
// ============================================================

test "Stress: 10 modules in chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // m0 → m1 → m2 → ... → m9 (각각 import + 값)
    try writeFile(tmp.dir, "m0.ts", "import './m1';\nconsole.log('m0');");
    try writeFile(tmp.dir, "m1.ts", "import './m2';\nconsole.log('m1');");
    try writeFile(tmp.dir, "m2.ts", "import './m3';\nconsole.log('m2');");
    try writeFile(tmp.dir, "m3.ts", "import './m4';\nconsole.log('m3');");
    try writeFile(tmp.dir, "m4.ts", "import './m5';\nconsole.log('m4');");
    try writeFile(tmp.dir, "m5.ts", "import './m6';\nconsole.log('m5');");
    try writeFile(tmp.dir, "m6.ts", "import './m7';\nconsole.log('m6');");
    try writeFile(tmp.dir, "m7.ts", "import './m8';\nconsole.log('m7');");
    try writeFile(tmp.dir, "m8.ts", "import './m9';\nconsole.log('m8');");
    try writeFile(tmp.dir, "m9.ts", "console.log('m9');");

    const entry = try absPath(&tmp, "m0.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // m9가 가장 먼저, m0이 가장 나중
    const m9_pos = std.mem.indexOf(u8, result.output, "\"m9\"") orelse return error.TestUnexpectedResult;
    const m0_pos = std.mem.indexOf(u8, result.output, "\"m0\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(m9_pos < m0_pos);
}

test "Stress: wide fan-in (many modules import same leaf)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a'; import './b'; import './c'; import './d';
        \\console.log('entry');
    );
    try writeFile(tmp.dir, "a.ts", "import { x } from './leaf';\nconsole.log('a', x);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './leaf';\nconsole.log('b', x);");
    try writeFile(tmp.dir, "c.ts", "import { x } from './leaf';\nconsole.log('c', x);");
    try writeFile(tmp.dir, "d.ts", "import { x } from './leaf';\nconsole.log('d', x);");
    try writeFile(tmp.dir, "leaf.ts", "export const x = 'shared';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // leaf 코드는 한 번만 포함
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "\"shared\"")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Stress: multiple entry points with deep shared graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts", "import { a } from './a';\nconsole.log('e1', a);");
    try writeFile(tmp.dir, "e2.ts", "import { b } from './b';\nconsole.log('e2', b);");
    try writeFile(tmp.dir, "a.ts", "import { common } from './common';\nexport const a = common + '-a';");
    try writeFile(tmp.dir, "b.ts", "import { common } from './common';\nexport const b = common + '-b';");
    try writeFile(tmp.dir, "common.ts", "export const common = 'shared-base';");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shared-base\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"e1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"e2\"") != null);
}
