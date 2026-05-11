const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking: innerGraph prunes overwritten assignment inside ESM exported function body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export function runAll() {
        \\  let value;
        \\  value = "INNER_GRAPH_ESM_FN_DEAD_WRITE";
        \\  value = "INNER_GRAPH_ESM_FN_FINAL_WRITE";
        \\  return value;
        \\}
        \\console.log(runAll());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_FN_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_FN_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside ESM exported arrow body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const runAll = () => {
        \\  let value;
        \\  value = "INNER_GRAPH_ESM_ARROW_DEAD_WRITE";
        \\  value = "INNER_GRAPH_ESM_ARROW_FINAL_WRITE";
        \\  return value;
        \\};
        \\console.log(runAll());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_ARROW_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_ARROW_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph preserves destructuring declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let { value } = { value: "INNER_GRAPH_DESTRUCT_INIT" };
        \\value = "INNER_GRAPH_DESTRUCT_FINAL";
        \\console.log(value);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_DESTRUCT_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_DESTRUCT_FINAL") != null);
}

test "TreeShaking: innerGraph preserves multi-declarator declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let first = "INNER_GRAPH_MULTI_INIT", second = "INNER_GRAPH_MULTI_SECOND";
        \\first = "INNER_GRAPH_MULTI_FINAL";
        \\console.log(first, second);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MULTI_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MULTI_SECOND") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MULTI_FINAL") != null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside function body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function read() {
        \\  let value;
        \\  value = "INNER_GRAPH_FN_DEAD_WRITE";
        \\  value = "INNER_GRAPH_FN_FINAL_WRITE";
        \\  return value;
        \\}
        \\console.log(read());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten declaration initializer inside function body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function read() {
        \\  let value = "INNER_GRAPH_FN_DEAD_INIT";
        \\  value = "INNER_GRAPH_FN_INIT_FINAL";
        \\  return value;
        \\}
        \\console.log(read());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_INIT_FINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FN_DEAD_INIT") == null);
}

test "TreeShaking: innerGraph prunes overwritten assignment inside block body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\{
        \\  let value;
        \\  value = "INNER_GRAPH_BLOCK_DEAD_WRITE";
        \\  value = "INNER_GRAPH_BLOCK_FINAL_WRITE";
        \\  console.log(value);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten declaration initializer inside block body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\{
        \\  let value = "INNER_GRAPH_BLOCK_DEAD_INIT";
        \\  value = "INNER_GRAPH_BLOCK_INIT_FINAL";
        \\  console.log(value);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_INIT_FINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_BLOCK_DEAD_INIT") == null);
}

test "TreeShaking: innerGraph preserves function body assignment captured by closure before overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\function read() {
        \\  let value;
        \\  value = "INNER_GRAPH_CAPTURED_WRITE";
        \\  const capture = () => value;
        \\  value = "INNER_GRAPH_AFTER_CAPTURE";
        \\  return [capture(), value];
        \\}
        \\console.log(read());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_CAPTURED_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_AFTER_CAPTURE") != null);
}

test "TreeShaking: innerGraph preserves overwritten assignment inside control-flow block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\if (Math.random()) {
        \\  value = "INNER_GRAPH_IF_BLOCK_WRITE";
        \\  value = "INNER_GRAPH_IF_BLOCK_FINAL";
        \\  console.log(value);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_IF_BLOCK_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_IF_BLOCK_FINAL") != null);
}
