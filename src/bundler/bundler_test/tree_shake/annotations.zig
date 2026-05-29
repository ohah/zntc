const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// @__PURE__ annotation tests
// ============================================================

test "@__PURE__: annotation preserved in call expression output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: annotation preserved with #__PURE__ syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* #__PURE__ */ bar();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: annotation on new expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ new Foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: no annotation when not present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@__PURE__") == null);
}

test "@__PURE__: annotation not emitted in minify mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@__PURE__") == null);
}

test "@__PURE__: applies to first call only in chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // /* @__PURE__ */ a().b() → @__PURE__는 a()에만, b()에는 적용 안 됨
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ a().b();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // @__PURE__가 정확히 1번만 출력
    const output = result.output;
    const first = std.mem.indexOf(u8, output, "/* @__PURE__ */");
    try std.testing.expect(first != null);
    // 두 번째가 없어야 함
    if (first) |pos| {
        try std.testing.expect(std.mem.indexOf(u8, output[pos + 15 ..], "/* @__PURE__ */") == null);
    }
}

test "@__PURE__: preserved across modules in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { create } from './b'; const x = /* @__PURE__ */ create();");
    try writeFile(tmp.dir, "b.ts", "export function create() { return {}; }");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// @__NO_SIDE_EFFECTS__ tests
// ============================================================

test "@__NO_SIDE_EFFECTS__: function flag preserved in bundle output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // @__NO_SIDE_EFFECTS__ 함수를 import해서 호출
    try writeFile(tmp.dir, "entry.ts",
        \\import { create } from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function create") != null);
    // cross-module @__NO_SIDE_EFFECTS__ 전파: import한 함수의 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: call to annotated function auto-pure in single file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ function create() { return {}; }
        \\const x = create();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // create() 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: function expression variant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\const make = /* @__NO_SIDE_EFFECTS__ */ function() { return {}; };
        \\const x = make();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // make() 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: cross-module re-export chain" {
    // a.ts → b.ts (re-export) → c.ts (원본 @__NO_SIDE_EFFECTS__)
    // a.ts에서 호출 시 /* @__PURE__ */ 출력되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { create } from './re-export';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "re-export.ts", "export { create } from './lib';");
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: cross-module multiple imports" {
    // 여러 함수 중 하나만 @__NO_SIDE_EFFECTS__ — 해당 호출만 pure
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { pure, impure } from './lib';
        \\const a = pure();
        \\const b = impure();
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ export function pure() { return 1; }
        \\export function impure() { return 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // pure() 호출에만 /* @__PURE__ */ 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
    // /* @__PURE__ */ 는 1번만 나와야 함 (impure() 호출에는 없음)
    const first = std.mem.indexOf(u8, result.output, "/* @__PURE__ */").?;
    const second = std.mem.indexOf(u8, result.output[first + 1 ..], "/* @__PURE__ */");
    try std.testing.expect(second == null);
}

test "@__NO_SIDE_EFFECTS__: cross-module default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import create from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export default function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: no false positive on normal import" {
    // @__NO_SIDE_EFFECTS__ 없는 함수는 pure 마킹 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { normal } from './lib';
        \\const x = normal();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "export function normal() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // /* @__PURE__ */ 가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") == null);
}

test "@__NO_SIDE_EFFECTS__: export default async function" {
    // async 키워드가 @__NO_SIDE_EFFECTS__ 전파를 끊지 않는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import create from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export default async function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: export async function (named)" {
    // export async function도 @__NO_SIDE_EFFECTS__ 전파됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchData } from './lib';
        \\const x = fetchData();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export async function fetchData() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: single-file async function" {
    // 단일 파일에서도 async function @__NO_SIDE_EFFECTS__ 동작 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ async function create() { return {}; }
        \\const x = create();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}
