const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking: preserves top-level assignment to ESM export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export let value;
        \\value = "INNER_GRAPH_ESM_TOP_LEVEL_WRITE";
        \\value = "INNER_GRAPH_ESM_TOP_LEVEL_FINAL";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_TOP_LEVEL_FINAL") != null);
}

test "TreeShaking: preserves imported top-level assignment to ESM export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from "./dep";
        \\console.log(value);
    );
    try writeFile(tmp.dir, "dep.ts",
        \\export let value;
        \\value = "INNER_GRAPH_ESM_IMPORTED_WRITE";
        \\value = "INNER_GRAPH_ESM_IMPORTED_FINAL";
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ESM_IMPORTED_FINAL") != null);
}

test "TreeShaking: preserves lru-cache style async assignment to ESM export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { metrics, tracing } from "./dep";
        \\console.log(metrics.hasSubscribers, tracing.hasSubscribers);
    );
    try writeFile(tmp.dir, "dep.ts",
        \\const dummy = { hasSubscribers: false };
        \\export let metrics = dummy;
        \\export let tracing = dummy;
        \\Promise.resolve({
        \\  channel() { return { hasSubscribers: "INNER_GRAPH_LRU_METRICS_FINAL" }; },
        \\  tracingChannel() { return { hasSubscribers: "INNER_GRAPH_LRU_TRACING_FINAL" }; },
        \\}).then((dc) => {
        \\  metrics = dc.channel("lru-cache:metrics");
        \\  tracing = dc.tracingChannel("lru-cache");
        \\});
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_LRU_METRICS_FINAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_LRU_TRACING_FINAL") != null);
}

test "TreeShaking: preserves reanimated style conditional assignment to ESM export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { measure } from "./dep";
        \\console.log(measure);
    );
    try writeFile(tmp.dir, "dep.ts",
        \\export let measure;
        \\function measureNative() { return "INNER_GRAPH_REANIMATED_NATIVE"; }
        \\function measureDefault() { return "INNER_GRAPH_REANIMATED_DEFAULT"; }
        \\if (globalThis.__INNER_GRAPH_NATIVE__) {
        \\  measure = measureNative;
        \\} else {
        \\  measure = measureDefault;
        \\}
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_REANIMATED_NATIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_REANIMATED_DEFAULT") != null);
}

test "TreeShaking: preserves tslib style self reassignment in ESM export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { assign } from "./dep";
        \\console.log(assign);
    );
    try writeFile(tmp.dir, "dep.ts",
        \\export var assign = function () {
        \\  assign = Object.assign || function assignFallback(target) {
        \\    target.marker = "INNER_GRAPH_TSLIB_ASSIGN_FALLBACK";
        \\    return target;
        \\  };
        \\  return assign.apply(this, arguments);
        \\};
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_TSLIB_ASSIGN_FALLBACK") != null);
}
