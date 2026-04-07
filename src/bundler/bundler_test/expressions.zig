const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// Error cases: more thorough
// ============================================================

test "Error: syntax error in dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './bad';\nconsole.log('ok');");
    try writeFile(tmp.dir, "bad.ts", "const = ;"); // 구문 오류

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 구문 오류가 있는 모듈 → 에러 또는 번들 생성 (에러 복구에 따라)
    // 최소한 크래시하지 않아야 함
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Error: circular re-export chain" {
    // A re-exports from B, B re-exports from A → 무한 루프 방지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './a';\nconsole.log(x);");
    try writeFile(tmp.dir, "a.ts", "export { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './a';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 무한 루프에 빠지지 않고 완료해야 함 (에러 보고 가능)
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Error: entry point not found" {
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{"/nonexistent/path/entry.ts"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
}

// ============================================================
// Re-export advanced: Rollup form/samples 참고
// ============================================================

test "Re-export: export * from multiple sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c } from './all';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "all.ts",
        \\export * from './src-a';
        \\export * from './src-b';
    );
    try writeFile(tmp.dir, "src-a.ts", "export const a = 'A';\nexport const b = 'B';");
    try writeFile(tmp.dir, "src-b.ts", "export const c = 'C';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"C\"") != null);
}

test "Re-export: mixed named and star from same module" {
    // Rolldown #7233: 같은 모듈에서 named + star 동시
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y, z } from './proxy';
        \\console.log(x, y, z);
    );
    try writeFile(tmp.dir, "proxy.ts",
        \\export { x } from './source';
        \\export * from './source';
    );
    try writeFile(tmp.dir, "source.ts",
        \\export const x = 'X';
        \\export const y = 'Y';
        \\export const z = 'Z';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Z\"") != null);
}

test "Re-export: re-export default as named" {
    // export { default as Foo } from './foo'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo } from './proxy';
        \\console.log(Foo);
    );
    try writeFile(tmp.dir, "proxy.ts", "export { default as Foo } from './foo';");
    try writeFile(tmp.dir, "foo.ts", "export default 'default-foo';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default-foo\"") != null);
}

test "Stress: all formats + minify combinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './dep';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 6가지 조합 모두 성공해야 함
    const formats = [_]emitter.EmitOptions.Format{ .esm, .cjs, .iife };
    const minify_opts = [_]bool{ false, true };
    for (formats) |fmt| {
        for (minify_opts) |minify| {
            var b = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .format = fmt,
                .minify_whitespace = minify,
                .minify_identifiers = minify,
                .minify_syntax = minify,
            });
            defer b.deinit();
            const result = try b.bundle();
            defer result.deinit(std.testing.allocator);

            try std.testing.expect(!result.hasErrors());
            try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
        }
    }
}

// ============================================================
// Inline type import edge cases
// ============================================================

test "TypeScript: import type only specifiers all stripped" {
    // 모든 specifier가 type-only → import 문 자체가 side-effect only가 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type Foo, type Bar } from './types';
        \\console.log('no types used');
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface Foo { x: number; }
        \\export interface Bar { y: string; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no types used\"") != null);
}

test "TypeScript: import { type } as value name" {
    // import { type } → 'type'이라는 값 import (modifier 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type } from './mod';
        \\console.log(type);
    );
    try writeFile(tmp.dir, "mod.ts", "export const type = 'my-type-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"my-type-value\"") != null);
}

// ============================================================
// Declare module patterns
// ============================================================

test "TypeScript: declare module '*.svg' stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { render } from './app';
        \\render();
    );
    try writeFile(tmp.dir, "app.ts",
        \\declare module '*.svg' { const src: string; export default src; }
        \\declare module '*.png' { const src: string; export default src; }
        \\export function render() { console.log('rendered'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "declare") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"rendered\"") != null);
}

// ============================================================
// Parameter property patterns
// ============================================================

test "TypeScript: parameter property with multiple modifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Config } from './config';
        \\const c = new Config('prod', true);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export class Config {
        \\  constructor(public readonly env: string, private debug: boolean) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.env") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.debug") != null);
    // 접근 제어자 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "public") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readonly") == null);
}

test "TypeScript: parameter property with default value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Server } from './server';
        \\const s = new Server();
        \\console.log(s);
    );
    try writeFile(tmp.dir, "server.ts",
        \\export class Server {
        \\  constructor(public port: number = 3000) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.port") != null);
}

// ============================================================
// New expression patterns (bug regression tests)
// ============================================================

test "New expression: basic constructor call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo } from './foo';
        \\const f = new Foo();
        \\console.log(f);
    );
    try writeFile(tmp.dir, "foo.ts", "export class Foo { x = 1; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Foo()") != null);
}

test "New expression: with arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Vec2 } from './vec';
        \\const v = new Vec2(10, 20);
        \\console.log(v);
    );
    try writeFile(tmp.dir, "vec.ts",
        \\export class Vec2 {
        \\  constructor(public x: number, public y: number) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Vec2(10, 20)") != null);
}

test "New expression: nested new" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Wrapper, Inner } from './classes';
        \\const w = new Wrapper(new Inner());
        \\console.log(w);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class Inner { val = 'inner'; }
        \\export class Wrapper { constructor(public child: Inner) {} }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Inner") != null);
}

// ============================================================
// Default export regression tests
// ============================================================

test "Default: default export object literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config from './config';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export default { host: 'localhost', port: 8080 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"localhost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "8080") != null);
}

test "Default: default export array literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import items from './items';
        \\console.log(items);
    );
    try writeFile(tmp.dir, "items.ts",
        \\export default ['a', 'b', 'c'];
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"b\"") != null);
}

test "Default: default export used in expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import multiplier from './multiplier';
        \\const result = multiplier * 10;
        \\console.log(result);
    );
    try writeFile(tmp.dir, "multiplier.ts", "export default 5;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "* 10") != null);
}

// ============================================================
// Codegen formatting regression tests
// ============================================================

test "Codegen: object literal formatting non-minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = { x: 1, y: 2, z: 3 };
        \\console.log(obj);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = false });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // non-minify: 콜론 뒤 공백, 쉼표 뒤 공백
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "y: 2") != null);
}

test "Codegen: object literal formatting minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = { x: 1, y: 2 };
        \\console.log(obj);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minify: 공백 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x:1") != null);
}

test "Codegen: array literal formatting non-minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const arr = [10, 20, 30];
        \\console.log(arr);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = false });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[10, 20, 30]") != null);
}

test "Codegen: array literal formatting minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const arr = [10, 20, 30];
        \\console.log(arr);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[10,20,30]") != null);
}

// ============================================================
// Complex class patterns across modules
// ============================================================

test "Class: inheritance chain across 3 modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Cat } from './cat';
        \\const c = new Cat('Mimi');
        \\console.log(c.speak());
    );
    try writeFile(tmp.dir, "cat.ts",
        \\import { Pet } from './pet';
        \\export class Cat extends Pet {
        \\  speak() { return this.name + ' meows'; }
        \\}
    );
    try writeFile(tmp.dir, "pet.ts",
        \\export class Pet {
        \\  name: string;
        \\  constructor(name: string) { this.name = name; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // Pet → Cat → entry 순서
    const pet_pos = std.mem.indexOf(u8, result.output, "class Pet") orelse return error.TestUnexpectedResult;
    const cat_pos = std.mem.indexOf(u8, result.output, "class Cat") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pet_pos < cat_pos);
}

test "Class: static methods across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MathUtils } from './math-utils';
        \\console.log(MathUtils.clamp(15, 0, 10));
    );
    try writeFile(tmp.dir, "math-utils.ts",
        \\export class MathUtils {
        \\  static clamp(val: number, min: number, max: number): number {
        \\    return Math.min(Math.max(val, min), max);
        \\  }
        \\  static lerp(a: number, b: number, t: number): number {
        \\    return a + (b - a) * t;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class MathUtils") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "static clamp") != null);
}

// ============================================================
// Complex expression patterns
// ============================================================

test "Expression: optional chaining across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getUser } from './api';
        \\const name = getUser()?.name;
        \\console.log(name);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export function getUser() { return { name: 'Alice' }; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "?.name") != null);
}

test "Expression: nullish coalescing across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getValue } from './store';
        \\const result = getValue() ?? 'default';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "store.ts",
        \\export function getValue() { return null; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "??") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"default\"") != null);
}

test "Expression: logical assignment across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { config } from './config';
        \\config.debug ??= false;
        \\config.verbose ||= true;
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export const config: any = {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "??=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "||=") != null);
}

// ============================================================
// Advanced module patterns
// ============================================================

test "Module: re-export with rename chain" {
    // A exports x, B re-exports x as y, C re-exports y as z, entry imports z
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './c';
        \\console.log(z);
    );
    try writeFile(tmp.dir, "c.ts", "export { y as z } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x as y } from './a';");
    try writeFile(tmp.dir, "a.ts", "export const x = 'renamed-three-times';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"renamed-three-times\"") != null);
}

test "Module: side-effect import between value imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './a';
        \\import './side';
        \\import { b } from './b';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "a.ts", "export const a = 'A';");
    try writeFile(tmp.dir, "side.ts", "console.log('SIDE');");
    try writeFile(tmp.dir, "b.ts", "export const b = 'B';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // side-effect는 a와 b 사이에 실행
    const a_pos = std.mem.indexOf(u8, result.output, "\"A\"") orelse return error.TestUnexpectedResult;
    const side_pos = std.mem.indexOf(u8, result.output, "\"SIDE\"") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "\"B\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < side_pos);
    try std.testing.expect(side_pos < b_pos);
}

test "Module: import same default from two different modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import configA from './a';
        \\import configB from './b';
        \\console.log(configA, configB);
    );
    try writeFile(tmp.dir, "a.ts", "export default { name: 'A' };");
    try writeFile(tmp.dir, "b.ts", "export default { name: 'B' };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"B\"") != null);
}

// ============================================================
// Stress: large real-world-like patterns
// ============================================================

test "Stress: micro-framework with models, views, controllers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts",
        \\import { App } from './framework/app';
        \\import { UserModel } from './models/user';
        \\import { UserView } from './views/user';
        \\const app = new App();
        \\const model = new UserModel();
        \\const view = new UserView();
        \\console.log(app, model, view);
    );
    try writeFile(tmp.dir, "framework/app.ts",
        \\import { Router } from './router';
        \\export class App { router = new Router(); }
    );
    try writeFile(tmp.dir, "framework/router.ts",
        \\export class Router { routes: string[] = []; }
    );
    try writeFile(tmp.dir, "models/user.ts",
        \\import { BaseModel } from './base';
        \\export class UserModel extends BaseModel { table = 'users'; }
    );
    try writeFile(tmp.dir, "models/base.ts",
        \\export class BaseModel { id = 0; }
    );
    try writeFile(tmp.dir, "views/user.ts",
        \\import { BaseView } from './base';
        \\export class UserView extends BaseView { template = '<div/>'; }
    );
    try writeFile(tmp.dir, "views/base.ts",
        \\export class BaseView { el = 'body'; }
    );

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 클래스가 번들에 포함
    for ([_][]const u8{ "class App", "class Router", "class UserModel", "class BaseModel", "class UserView", "class BaseView" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
    // base 클래스가 derived보다 먼저
    const base_model_pos = std.mem.indexOf(u8, result.output, "class BaseModel") orelse return error.TestUnexpectedResult;
    const user_model_pos = std.mem.indexOf(u8, result.output, "class UserModel") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_model_pos < user_model_pos);
}

test "Stress: 15 modules with mixed patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry imports from barrel which re-exports from 5 modules, each importing shared
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c, d, e } from './barrel';
        \\console.log(a, b, c, d, e);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './modules/a';
        \\export { b } from './modules/b';
        \\export { c } from './modules/c';
        \\export { d } from './modules/d';
        \\export { e } from './modules/e';
    );
    try writeFile(tmp.dir, "modules/a.ts", "import { shared } from '../shared';\nexport const a = shared + '-a';");
    try writeFile(tmp.dir, "modules/b.ts", "import { shared } from '../shared';\nexport const b = shared + '-b';");
    try writeFile(tmp.dir, "modules/c.ts", "import { shared } from '../shared';\nexport const c = shared + '-c';");
    try writeFile(tmp.dir, "modules/d.ts", "import { shared } from '../shared';\nexport const d = shared + '-d';");
    try writeFile(tmp.dir, "modules/e.ts", "import { shared } from '../shared';\nexport const e = shared + '-e';");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'SHARED';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared는 한 번만 포함
    var count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "\"SHARED\"")) |pos| {
        count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// Control flow patterns across modules
// ============================================================

test "Control flow: for-of loop with imported iterable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { items } from './data';
        \\for (const item of items) { console.log(item); }
    );
    try writeFile(tmp.dir, "data.ts", "export const items = ['x', 'y', 'z'];");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "of") != null);
}

test "Control flow: for-in loop with imported object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { obj } from './data';
        \\for (const key in obj) { console.log(key); }
    );
    try writeFile(tmp.dir, "data.ts", "export const obj = { a: 1, b: 2 };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "for") != null);
}

test "Control flow: try-catch with imported error class" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { AppError } from './errors';
        \\try { throw new AppError('fail'); } catch (e) { console.log(e); }
    );
    try writeFile(tmp.dir, "errors.ts",
        \\export class AppError extends Error {
        \\  constructor(msg: string) { super(msg); }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class AppError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new AppError") != null);
}

test "Control flow: switch with imported enum values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Status } from './status';
        \\function handle(s: any) {
        \\  switch (s) {
        \\    case Status.OK: return 'ok';
        \\    case Status.ERR: return 'error';
        \\    default: return 'unknown';
        \\  }
        \\}
        \\console.log(handle(200));
    );
    try writeFile(tmp.dir, "status.ts", "export enum Status { OK = 200, ERR = 500 }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Status") != null);
}

test "Control flow: while loop with imported condition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MAX } from './limits';
        \\let i = 0;
        \\while (i < MAX) { i++; }
        \\console.log(i);
    );
    try writeFile(tmp.dir, "limits.ts", "export const MAX = 10;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MAX = 10") != null);
}

// ============================================================
// Promise / async patterns across modules
// ============================================================

test "Async: promise chain across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchUser } from './api';
        \\import { formatUser } from './format';
        \\fetchUser().then(formatUser).then(console.log);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export function fetchUser() {
        \\  return Promise.resolve({ name: 'Bob' });
        \\}
    );
    try writeFile(tmp.dir, "format.ts",
        \\export function formatUser(u: any) {
        \\  return u.name.toUpperCase();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function fetchUser") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function formatUser") != null);
}

test "Async: async/await with imported functions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { loadConfig } from './loader';
        \\async function main() {
        \\  const cfg = await loadConfig();
        \\  console.log(cfg);
        \\}
        \\main();
    );
    try writeFile(tmp.dir, "loader.ts",
        \\export async function loadConfig() {
        \\  return { db: 'postgres' };
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "await") != null);
}

test "Async: multiple async functions pipeline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { step1 } from './steps/s1';
        \\import { step2 } from './steps/s2';
        \\import { step3 } from './steps/s3';
        \\async function pipeline() {
        \\  const a = await step1();
        \\  const b = await step2(a);
        \\  return await step3(b);
        \\}
        \\pipeline().then(console.log);
    );
    try writeFile(tmp.dir, "steps/s1.ts", "export async function step1() { return 'one'; }");
    try writeFile(tmp.dir, "steps/s2.ts", "export async function step2(x: string) { return x + '-two'; }");
    try writeFile(tmp.dir, "steps/s3.ts", "export async function step3(x: string) { return x + '-three'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function step1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function step2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function step3") != null);
}

// ============================================================
// Built-in data structures across modules
// ============================================================

test "Builtins: Map usage across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createCache } from './cache';
        \\const cache = createCache();
        \\cache.set('key', 'value');
        \\console.log(cache.get('key'));
    );
    try writeFile(tmp.dir, "cache.ts",
        \\export function createCache() {
        \\  return new Map();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Map") != null);
}

test "Builtins: Set usage across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { uniqueItems } from './unique';
        \\console.log(uniqueItems([1, 2, 2, 3]));
    );
    try writeFile(tmp.dir, "unique.ts",
        \\export function uniqueItems(arr: number[]) {
        \\  return [...new Set(arr)];
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Set") != null);
}

test "Builtins: Symbol as key across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ID, createEntity } from './entity';
        \\const e = createEntity(42);
        \\console.log(e[ID]);
    );
    try writeFile(tmp.dir, "entity.ts",
        \\export const ID = Symbol('id');
        \\export function createEntity(id: number) {
        \\  return { [ID]: id, name: 'entity' };
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Symbol(") != null);
}

test "Builtins: Proxy across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createProxy } from './proxy';
        \\const p = createProxy({ x: 1 });
        \\console.log(p.x);
    );
    try writeFile(tmp.dir, "proxy.ts",
        \\export function createProxy(target: any) {
        \\  return new Proxy(target, {
        \\    get(t: any, prop: string) { return t[prop]; }
        \\  });
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Proxy") != null);
}
