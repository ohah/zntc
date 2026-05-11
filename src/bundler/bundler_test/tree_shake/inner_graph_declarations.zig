const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking: innerGraph prunes pure write-only assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = 1;
        \\value = "INNER_GRAPH_DEAD_WRITE";
        \\console.log("INNER_GRAPH_WRITE_ENTRY");
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_WRITE_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_DEAD_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten pure assignment before read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\value = "INNER_GRAPH_OVERWRITTEN_WRITE";
        \\value = "INNER_GRAPH_FINAL_WRITE";
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_FINAL_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_OVERWRITTEN_WRITE") == null);
}

test "TreeShaking: innerGraph prunes overwritten pure declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = "INNER_GRAPH_DEAD_INIT";
        \\value = "INNER_GRAPH_INIT_FINAL";
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_INIT_FINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_DEAD_INIT") == null);
}

test "TreeShaking: innerGraph preserves declaration initializer read before overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = "INNER_GRAPH_LIVE_INIT";
        \\console.log(value);
        \\value = "INNER_GRAPH_AFTER_INIT_READ";
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_LIVE_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_AFTER_INIT_READ") != null);
}

test "TreeShaking: innerGraph preserves side-effect declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = sideEffect();
        \\value = "INNER_GRAPH_SIDE_INIT_FINAL";
        \\console.log(value);
        \\function sideEffect() {
        \\  console.log("INNER_GRAPH_SIDE_INIT");
        \\  return 1;
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_INIT_FINAL") != null);
}

test "TreeShaking: innerGraph preserves exported declaration initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export let value = "INNER_GRAPH_EXPORTED_INIT";
        \\value = "INNER_GRAPH_EXPORTED_FINAL";
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_EXPORTED_INIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_EXPORTED_FINAL") != null);
}
