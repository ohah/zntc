const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking: innerGraph preserves assignment read before overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\value = "INNER_GRAPH_READ_BEFORE_OVERWRITE";
        \\console.log(value);
        \\value = "INNER_GRAPH_READ_AFTER_OVERWRITE";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_READ_BEFORE_OVERWRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_READ_AFTER_OVERWRITE") != null);
}

test "TreeShaking: innerGraph preserves assignment with side-effect RHS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = 1;
        \\value = sideEffect();
        \\console.log("INNER_GRAPH_SIDE_WRITE_ENTRY");
        \\function sideEffect() {
        \\  console.log("INNER_GRAPH_SIDE_WRITE");
        \\  return 2;
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_WRITE_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_WRITE") != null);
}

test "TreeShaking: innerGraph preserves overwritten assignment with side-effect RHS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\value = sideEffect();
        \\value = "INNER_GRAPH_SIDE_OVERWRITE_FINAL";
        \\console.log(value);
        \\function sideEffect() {
        \\  console.log("INNER_GRAPH_SIDE_OVERWRITE");
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_OVERWRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_OVERWRITE_FINAL") != null);
}

test "TreeShaking: innerGraph preserves assignment whose value is read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = 1;
        \\value = "INNER_GRAPH_LIVE_WRITE";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_LIVE_WRITE") != null);
}

test "TreeShaking: innerGraph preserves compound assignment before overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = 1;
        \\value += 2;
        \\value = "INNER_GRAPH_COMPOUND_FINAL";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value += 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_COMPOUND_FINAL") != null);
}

test "TreeShaking: innerGraph preserves update expression before overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = 1;
        \\value++;
        \\value = "INNER_GRAPH_UPDATE_FINAL";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "value++") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_UPDATE_FINAL") != null);
}

test "TreeShaking: innerGraph Reference matching keeps shadowed symbols distinct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\value = "INNER_GRAPH_SHADOW_OUTER_DEAD";
        \\{
        \\  let value;
        \\  value = "INNER_GRAPH_SHADOW_INNER_LIVE";
        \\  console.log(value);
        \\}
        \\value = "INNER_GRAPH_SHADOW_OUTER_FINAL";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SHADOW_OUTER_DEAD") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SHADOW_INNER_LIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SHADOW_OUTER_FINAL") != null);
}

test "TreeShaking: innerGraph ignores type-only references for overwrite liveness" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value = "INNER_GRAPH_TYPE_ONLY_INIT";
        \\type Box = typeof value;
        \\value = "INNER_GRAPH_TYPE_ONLY_FINAL";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_TYPE_ONLY_INIT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_TYPE_ONLY_FINAL") != null);
}

test "TreeShaking: innerGraph preserves previous write before RHS self-read overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\let value;
        \\value = "INNER_GRAPH_SELF_READ_PREV";
        \\value = value + "INNER_GRAPH_SELF_READ_NEXT";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SELF_READ_PREV") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SELF_READ_NEXT") != null);
}

test "TreeShaking: innerGraph preserves member assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = {};
        \\obj.value = "INNER_GRAPH_MEMBER_WRITE";
        \\console.log("INNER_GRAPH_MEMBER_ENTRY");
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MEMBER_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_MEMBER_WRITE") != null);
}

test "TreeShaking: innerGraph preserves global assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\globalThis.value = "INNER_GRAPH_GLOBAL_WRITE";
        \\console.log("INNER_GRAPH_GLOBAL_ENTRY");
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_GLOBAL_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_GLOBAL_WRITE") != null);
}
