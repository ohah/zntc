const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking inner graph and write-liveness tests
// ============================================================

test "TreeShaking: innerGraph prunes unused pure entry locals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const used = "INNER_GRAPH_USED_CONST";
        \\const unused = "INNER_GRAPH_UNUSED_CONST";
        \\function usedFn() { return "INNER_GRAPH_USED_FN"; }
        \\function unusedFn() { return "INNER_GRAPH_UNUSED_FN"; }
        \\console.log(used, usedFn());
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_USED_CONST") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_USED_FN") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_UNUSED_CONST") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_UNUSED_FN") == null);
}

test "TreeShaking: --pure callee hints prune unused exact and wildcard calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const used = makeUsed("PURE_USED_CALL");
        \\const unused = makeUnused("PURE_UNUSED_CALL");
        \\const element = React.createElement("div", { title: "PURE_REACT_CALL" });
        \\const prop = PropTypes.string.isRequired("PURE_WILDCARD_CALL");
        \\React.cloneElement("PURE_NONMATCHING_MEMBER_CALL");
        \\console.log(used);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_syntax = true,
        .tree_shaking = true,
        .pure = &.{ "makeUnused", "React.createElement", "PropTypes.*" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_USED_CALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_UNUSED_CALL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_REACT_CALL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_WILDCARD_CALL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_NONMATCHING_MEMBER_CALL") != null);
}

test "TreeShaking: innerGraph preserves entry side-effect initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const unused = sideEffect();
        \\console.log("INNER_GRAPH_ENTRY");
        \\function sideEffect() {
        \\  console.log("INNER_GRAPH_SIDE_EFFECT_INIT");
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_SIDE_EFFECT_INIT") != null);
}

test "TreeShaking: innerGraph preserves entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export const publicValue = "INNER_GRAPH_PUBLIC_EXPORT";
        \\const privateUnused = "INNER_GRAPH_PRIVATE_UNUSED";
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_PUBLIC_EXPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_PRIVATE_UNUSED") == null);
}

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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_TSLIB_ASSIGN_FALLBACK") != null);
}

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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_GLOBAL_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INNER_GRAPH_GLOBAL_WRITE") != null);
}
