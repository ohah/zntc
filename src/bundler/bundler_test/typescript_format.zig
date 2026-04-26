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
// TypeScript-specific bundling
// ============================================================

test "TypeScript: interface stripping across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { User } from './types';\nconst u: User = { name: 'test' };\nconsole.log(u);");
    try writeFile(tmp.dir, "types.ts", "export interface User { name: string; }\nexport interface Config { debug: boolean; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 인터페이스는 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    // 값 코드는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"test\"") != null);
}

test "TypeScript: enum across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Color } from './enums';\nconsole.log(Color.Red);");
    try writeFile(tmp.dir, "enums.ts", "export enum Color { Red, Green, Blue }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // enum → IIFE 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Color") != null);
}

test "TypeScript: type annotation stripping in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { process } from './processor';
        \\const result: string = process(42);
        \\console.log(result);
    );
    try writeFile(tmp.dir, "processor.ts",
        \\export function process(input: number): string {
        \\  return String(input);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 타입 어노테이션 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
    // 로직은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "String(input)") != null);
}

test "TypeScript: class with generics across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Container } from './container';
        \\const c = new Container(42);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "container.ts",
        \\export class Container<T> {
        \\  value: T;
        \\  constructor(v: T) { this.value = v; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 제네릭 타입 파라미터 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<T>") == null);
    // 클래스 구조는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Container") != null);
}

test "TypeScript: mixed type and value exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { API_URL, type Config } from './config';
        \\const url: Config = { url: API_URL };
        \\console.log(url);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export type Config = { url: string };
        \\export const API_URL = 'https://api.example.com';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // type은 제거, 값은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type Config") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"https://api.example.com\"") != null);
}

// ============================================================
// Deep dependency chains
// ============================================================

test "Deep chain: four-level (A→B→C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconsole.log('b');");
    try writeFile(tmp.dir, "c.ts", "import './d';\nconsole.log('c');");
    try writeFile(tmp.dir, "d.ts", "console.log('d');");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 실행 순서: d → c → b → a (DFS 후위)
    const d_pos = std.mem.indexOf(u8, result.output, "\"d\"") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, result.output, "\"c\"") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "\"b\"") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "\"a\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_pos < c_pos);
    try std.testing.expect(c_pos < b_pos);
    try std.testing.expect(b_pos < a_pos);
}

test "Deep chain: wide fan-out (entry imports 5 modules)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './m1';\nimport './m2';\nimport './m3';\nimport './m4';\nimport './m5';\nconsole.log('done');");
    try writeFile(tmp.dir, "m1.ts", "console.log('m1');");
    try writeFile(tmp.dir, "m2.ts", "console.log('m2');");
    try writeFile(tmp.dir, "m3.ts", "console.log('m3');");
    try writeFile(tmp.dir, "m4.ts", "console.log('m4');");
    try writeFile(tmp.dir, "m5.ts", "console.log('m5');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 모듈 포함
    for ([_][]const u8{ "\"m1\"", "\"m2\"", "\"m3\"", "\"m4\"", "\"m5\"", "\"done\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
    // entry(done)이 가장 마지막
    const done_pos = std.mem.indexOf(u8, result.output, "\"done\"") orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "\"m1\"", "\"m2\"", "\"m3\"", "\"m4\"", "\"m5\"" }) |needle| {
        const pos = std.mem.indexOf(u8, result.output, needle) orelse return error.TestUnexpectedResult;
        try std.testing.expect(pos < done_pos);
    }
}

test "Deep chain: diamond dependency (A→B,C; B→D; C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { b } from './b';\nimport { c } from './c';\nconsole.log(b, c);");
    try writeFile(tmp.dir, "b.ts", "import { d } from './d';\nexport const b = d + 1;");
    try writeFile(tmp.dir, "c.ts", "import { d } from './d';\nexport const c = d + 2;");
    try writeFile(tmp.dir, "d.ts", "export const d = 100;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // d가 b, c보다 먼저 (공유 leaf)
    const d_pos = std.mem.indexOf(u8, result.output, "const d = 100;") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "d + 1") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, result.output, "d + 2") orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_pos < b_pos);
    try std.testing.expect(d_pos < c_pos);
}

// ============================================================
// Real-world patterns (Webpack/Rolldown/esbuild 참고)
// ============================================================

test "Real-world: utils module pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { capitalize, slugify } from './utils';
        \\console.log(capitalize('hello'), slugify('Hello World'));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function capitalize(s: string): string {
        \\  return s.charAt(0).toUpperCase() + s.slice(1);
        \\}
        \\export function slugify(s: string): string {
        \\  return s.toLowerCase().replace(/ /g, '-');
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function capitalize") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function slugify") != null);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
}

test "Real-world: constants module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { MAX_RETRIES, TIMEOUT, BASE_URL } from './constants';
        \\console.log(MAX_RETRIES, TIMEOUT, BASE_URL);
    );
    try writeFile(tmp.dir, "constants.ts",
        \\export const MAX_RETRIES = 3;
        \\export const TIMEOUT = 5000;
        \\export const BASE_URL = '/api/v1';
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MAX_RETRIES = 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TIMEOUT = 5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"/api/v1\"") != null);
}

test "Real-world: class with imported dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { Logger } from './logger';
        \\const log = new Logger('app');
        \\log.info('started');
    );
    try writeFile(tmp.dir, "logger.ts",
        \\import { formatDate } from './date';
        \\export class Logger {
        \\  prefix: string;
        \\  constructor(p: string) { this.prefix = p; }
        \\  info(msg: string) { console.log(formatDate() + ' ' + this.prefix + ': ' + msg); }
        \\}
    );
    try writeFile(tmp.dir, "date.ts",
        \\export function formatDate(): string {
        \\  return new Date().toISOString();
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3모듈 번들: date → logger → app 순서
    const date_pos = std.mem.indexOf(u8, result.output, "function formatDate") orelse return error.TestUnexpectedResult;
    const logger_pos = std.mem.indexOf(u8, result.output, "class Logger") orelse return error.TestUnexpectedResult;
    const app_pos = std.mem.indexOf(u8, result.output, "new Logger") orelse return error.TestUnexpectedResult;
    try std.testing.expect(date_pos < logger_pos);
    try std.testing.expect(logger_pos < app_pos);
}

test "Real-world: event emitter pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { EventBus } from './events';
        \\const bus = new EventBus();
        \\bus.on('click', () => console.log('clicked'));
    );
    try writeFile(tmp.dir, "events.ts",
        \\export class EventBus {
        \\  listeners: Record<string, Function[]> = {};
        \\  on(event: string, fn: Function) {
        \\    if (!this.listeners[event]) this.listeners[event] = [];
        \\    this.listeners[event].push(fn);
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class EventBus") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new EventBus") != null);
}

test "Real-world: re-export from node_modules (external)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import React from 'react';
        \\import { useState } from 'react';
        \\import { render } from './renderer';
        \\render();
    );
    try writeFile(tmp.dir, "renderer.ts",
        \\export function render() { console.log('render'); }
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 로컬 모듈은 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function render") != null);
}

// ============================================================
// Output format tests (all formats with same input)
// ============================================================

test "Format: ESM preserves export in entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const version = '1.0.0';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"1.0.0\"") != null);
}

test "Format: CJS with multiple modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 'cjs-test';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"cjs-test\"") != null);
}

test "Format: IIFE with multiple modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './greeter';\ngreet();");
    try writeFile(tmp.dir, "greeter.ts", "export function greet() { console.log('hello'); }");

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
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(() => {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
}

test "Format: minified IIFE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './m';\nconsole.log(x);");
    try writeFile(tmp.dir, "m.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(() => {\n"));
    // 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "Format: minified CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const msg = 'hello';\nconsole.log(msg);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
}

// ============================================================
// Edge cases
// ============================================================

test "Edge: empty module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './empty';\nconsole.log('ok');");
    try writeFile(tmp.dir, "empty.ts", "");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ok\"") != null);
}

test "Edge: module with only comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './commented';\nconsole.log('works');");
    try writeFile(tmp.dir, "commented.ts", "// This is just a comment\n/* block comment */");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"works\"") != null);
}

test "Edge: side-effect only imports preserve execution order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './init1';\nimport './init2';\nimport './init3';\nconsole.log('app');");
    try writeFile(tmp.dir, "init1.ts", "console.log('init1');");
    try writeFile(tmp.dir, "init2.ts", "console.log('init2');");
    try writeFile(tmp.dir, "init3.ts", "console.log('init3');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // import 순서대로 실행: init1 → init2 → init3 → app
    const p1 = std.mem.indexOf(u8, result.output, "\"init1\"") orelse return error.TestUnexpectedResult;
    const p2 = std.mem.indexOf(u8, result.output, "\"init2\"") orelse return error.TestUnexpectedResult;
    const p3 = std.mem.indexOf(u8, result.output, "\"init3\"") orelse return error.TestUnexpectedResult;
    const pa = std.mem.indexOf(u8, result.output, "\"app\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(p1 < p2);
    try std.testing.expect(p2 < p3);
    try std.testing.expect(p3 < pa);
}

test "Edge: same module imported by multiple parents (dedup)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './shared';
        \\import { getX } from './helper';
        \\console.log(x, getX());
    );
    try writeFile(tmp.dir, "helper.ts",
        \\import { x } from './shared';
        \\export function getX() { return x; }
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared_value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared 모듈의 코드는 한 번만 포함
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "\"shared_value\"")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Edge: deeply nested directory imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/app/main.ts", "import { db } from '../lib/db/client';\nconsole.log(db);");
    try writeFile(tmp.dir, "src/lib/db/client.ts", "export const db = 'connected';");

    const entry = try absPath(&tmp, "src/app/main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"connected\"") != null);
}

test "Edge: export function and class from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createApp, App } from './framework';
        \\const app = createApp();
        \\console.log(app instanceof App);
    );
    try writeFile(tmp.dir, "framework.ts",
        \\export class App { name = 'app'; }
        \\export function createApp() { return new App(); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class App") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function createApp") != null);
}

test "Edge: multiple external packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import lodash from 'lodash';
        \\import axios from 'axios';
        \\import { local } from './local';
        \\console.log(local);
    );
    try writeFile(tmp.dir, "local.ts", "export const local = 'yes';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{ "react", "lodash", "axios" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
}

test "ESM external: import 구문 보존 (#1962 esbuild/rolldown 호환)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import { useState } from 'react';
        \\import * as lodash from 'lodash';
        \\console.log(React, useState, lodash);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{ "react", "lodash" },
        // format 기본값 = ESM
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM external: chunk top 에 ESM `import` 구문 prepend (esbuild/rolldown 동등).
    // require() 는 emit 되지 않아야 — Node ESM 파서에서 ReferenceError 발생.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(") == null);
    // default + named 는 같은 specifier 라 한 줄로 묶임.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"react\"") != null);
    // namespace 는 별도 라인 (ESM spec: `import * as ns, { x }` 불가).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import * as ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"lodash\"") != null);
}

test "CJS external: require preamble generated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\console.log(React);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // CJS 출력: require() preamble이 생성되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(") != null);
}

test "Edge: import with .js extension resolves to .ts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './lib.js';\nconsole.log(val);");
    try writeFile(tmp.dir, "lib.ts", "export const val = 'from-ts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-ts\"") != null);
}

test "Edge: index.ts resolution (directory import)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { hello } from './mylib';\nconsole.log(hello);");
    try writeFile(tmp.dir, "mylib/index.ts", "export const hello = 'world';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"world\"") != null);
}

// ============================================================
// Complex integration scenarios (esbuild/Rspack 참고)
// ============================================================

test "Complex: mixed import styles in one file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import def from './default';
        \\import { named } from './named';
        \\import './side-effect';
        \\console.log(def, named);
    );
    try writeFile(tmp.dir, "default.ts", "export default 'default_val';");
    try writeFile(tmp.dir, "named.ts", "export const named = 'named_val';");
    try writeFile(tmp.dir, "side-effect.ts", "console.log('side');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default_val\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named_val\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"side\"") != null);
}

test "Complex: transitive import chain with values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { result } from './compute';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "compute.ts",
        \\import { base } from './base';
        \\import { multiplier } from './config';
        \\export const result = base * multiplier;
    );
    try writeFile(tmp.dir, "base.ts", "export const base = 10;");
    try writeFile(tmp.dir, "config.ts", "export const multiplier = 5;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // base, config 가 compute보다 먼저
    const base_pos = std.mem.indexOf(u8, result.output, "base = 10") orelse return error.TestUnexpectedResult;
    const mult_pos = std.mem.indexOf(u8, result.output, "multiplier = 5") orelse return error.TestUnexpectedResult;
    const result_pos = std.mem.indexOf(u8, result.output, "base * multiplier") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_pos < result_pos);
    try std.testing.expect(mult_pos < result_pos);
}

test "Complex: multiple entry points sharing a module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "page1.ts", "import { shared } from './shared';\nconsole.log('page1', shared);");
    try writeFile(tmp.dir, "page2.ts", "import { shared } from './shared';\nconsole.log('page2', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const entry1 = try absPath(&tmp, "page1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "page2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"common\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"page1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"page2\"") != null);
}

test "Complex: platform node with external builtins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "server.ts",
        \\import fs from 'fs';
        \\import path from 'path';
        \\import { config } from './config';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts", "export const config = { port: 3000 };");

    const entry = try absPath(&tmp, "server.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // node builtins (fs, path) are external on node platform
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "port: 3000") != null);
}

test "Complex: arrow functions across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { double, triple } from './transforms';
        \\console.log(double(5), triple(3));
    );
    try writeFile(tmp.dir, "transforms.ts",
        \\export const double = (n: number) => n * 2;
        \\export const triple = (n: number) => n * 3;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n * 3") != null);
    // 타입 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
}

test "Complex: async function across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchData } from './api';
        \\fetchData().then(console.log);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export async function fetchData(): Promise<string> {
        \\  return 'data';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function fetchData") != null);
    // 리턴 타입 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Promise<string>") == null);
}

test "Complex: destructuring imports used in complex expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { width, height } from './dimensions';
        \\const area = width * height;
        \\const perimeter = 2 * (width + height);
        \\console.log({ area, perimeter });
    );
    try writeFile(tmp.dir, "dimensions.ts",
        \\export const width = 10;
        \\export const height = 20;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "width * height") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "width + height") != null);
}
