//! x_facebook_sources function map 번들러 통합 테스트.
//! sourcemap_function_map 옵션 활성화 시 번들 소스맵에 Metro 호환
//! x_facebook_sources 필드가 포함되는지 검증한다.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "bundler function_map: single-file — x_facebook_sources in sourcemap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "function hello() { return 42; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .sourcemap = true,
        .sourcemap_function_map = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    // x_facebook_sources 필드 존재
    try std.testing.expect(std.mem.indexOf(u8, sm, "x_facebook_sources") != null);
    // function map 내 이름 포함
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"<global>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"hello\"") != null);
    // Metro 형식: [[{names,mappings}]]
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"names\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"mappings\"") != null);
}

test "bundler function_map: multi-file — per-source entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");
    try writeFile(tmp.dir, "main.ts", "import { add } from './math';\nconst result = add(1, 2);");

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .sourcemap = true,
        .sourcemap_function_map = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    // x_facebook_sources 존재
    try std.testing.expect(std.mem.indexOf(u8, sm, "x_facebook_sources") != null);
    // math.ts에서 선언된 add 함수 이름이 맵에 포함
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"add\"") != null);
}

test "bundler function_map: disabled — no x_facebook_sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "function foo() {}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .sourcemap = true,
        // sourcemap_function_map 기본값 = false
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    // x_facebook_sources 미포함
    try std.testing.expect(std.mem.indexOf(u8, sm, "x_facebook_sources") == null);
}

test "bundler function_map: class methods — ClassName#method format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "class Widget { render() {} static create() {} }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .sourcemap = true,
        .sourcemap_function_map = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    try std.testing.expect(std.mem.indexOf(u8, sm, "x_facebook_sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"Widget#render\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"Widget.create\"") != null);
}
