const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Integration: core barrel and re-export patterns
// ============================================================

test "Integration: barrel file tree-shaking with sideEffects=false" {
    // barrel index에서 하나만 import → sideEffects=false면 미사용 모듈 제거
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "barrel/a.ts", "export const used = 'a';");
    try writeFile(tmp.dir, "barrel/b.ts", "export const unused = 'b';");
    try writeFile(tmp.dir, "barrel/package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // used가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    // sideEffects=false이므로 b.ts가 미사용 → 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"b\"") == null);
}

test "Integration: barrel file without sideEffects keeps all" {
    // sideEffects 필드 없으면 보수적으로 전부 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "lib/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "lib/a.ts", "export const used = 'a';");
    try writeFile(tmp.dir, "lib/b.ts",
        \\console.log('b side effect');
        \\export const unused = 'b';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    // sideEffects 없으므로 b.ts의 side effect 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "b side effect") != null);
}

test "Integration: diamond re-export resolves to same symbol" {
    // 같은 원본 symbol을 두 경로로 import → 선언이 한 번만 존재해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { shared as a } from './path-a';
        \\import { shared as b } from './path-b';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "path-a.ts", "export { shared } from './original';");
    try writeFile(tmp.dir, "path-b.ts", "export { shared } from './original';");
    try writeFile(tmp.dir, "original.ts", "export const shared = 'original';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared 선언이 한 번만 존재해야 함 (중복 불가)
    const first = std.mem.indexOf(u8, result.output, "\"original\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, result.output[first + 1 ..], "\"original\"") == null);
}

test "Integration: class extends across module boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Derived } from './derived';
        \\const d = new Derived();
        \\console.log(d.greet());
    );
    try writeFile(tmp.dir, "derived.ts",
        \\import { Base } from './base';
        \\export class Derived extends Base {
        \\  greet() { return super.greet() + ' world'; }
        \\}
    );
    try writeFile(tmp.dir, "base.ts",
        \\export class Base {
        \\  greet() { return 'hello'; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // scope hoisting 후에도 extends Base 참조가 유효해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extends Base") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Base") != null);
    // Base가 Derived보다 먼저 선언 (exec_index 순)
    const base_pos = std.mem.indexOf(u8, result.output, "class Base") orelse return error.TestUnexpectedResult;
    const derived_pos = std.mem.indexOf(u8, result.output, "class Derived") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_pos < derived_pos);
}

test "Integration: default and named re-export combined" {
    // default + named를 re-export하고 import — lodash-es/rxjs 패턴
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import theDefault, { named } from './re-export';
        \\console.log(theDefault, named);
    );
    try writeFile(tmp.dir, "re-export.ts", "export { default, named } from './lib';");
    try writeFile(tmp.dir, "lib.ts",
        \\export default function lib() { return 'default'; }
        \\export const named = 'named';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named\"") != null);
}

test "Integration: side-effect order with export star" {
    // export * 순서가 원본 import 순서와 일치해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { util } from './barrel';
        \\console.log(util);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './init';
        \\export * from './utils';
    );
    try writeFile(tmp.dir, "init.ts",
        \\console.log('1-init');
        \\export const init = true;
    );
    try writeFile(tmp.dir, "utils.ts",
        \\console.log('2-utils');
        \\export const util = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // init.ts가 utils.ts보다 먼저 실행 (import 순서)
    const init_pos = std.mem.indexOf(u8, result.output, "1-init") orelse return error.TestUnexpectedResult;
    const utils_pos = std.mem.indexOf(u8, result.output, "2-utils") orelse return error.TestUnexpectedResult;
    try std.testing.expect(init_pos < utils_pos);
}

test "Integration: deeply nested barrel re-exports" {
    // 3단 barrel: entry → barrel1 → barrel2 → lib
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { deep } from './barrel1';
        \\console.log(deep);
    );
    try writeFile(tmp.dir, "barrel1.ts", "export { deep } from './barrel2';");
    try writeFile(tmp.dir, "barrel2.ts", "export { deep } from './lib';");
    try writeFile(tmp.dir, "lib.ts", "export const deep = 'found';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"found\"") != null);
}

test "Integration: mixed default/named import from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import App, { version, config } from './app';
        \\console.log(App, version, config);
    );
    try writeFile(tmp.dir, "app.ts",
        \\export default class App { name = 'app'; }
        \\export const version = '1.0';
        \\export const config = { debug: true };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class App") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "debug") != null);
}
