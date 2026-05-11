const std = @import("std");
const bundler_mod = @import("../bundler.zig");
const Bundler = bundler_mod.Bundler;
const BundleResult = bundler_mod.BundleResult;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

fn resultHasModulePathEnding(result: *const BundleResult, suffix: []const u8) bool {
    const paths = result.module_paths orelse return false;
    for (paths) |path| {
        if (std.mem.endsWith(u8, path, suffix)) return true;
    }
    return false;
}

fn expectModulePathEnding(result: *const BundleResult, suffix: []const u8, expected: bool) !void {
    try std.testing.expectEqual(expected, resultHasModulePathEnding(result, suffix));
}

fn countModulePathsContaining(result: *const BundleResult, needle: []const u8) usize {
    const paths = result.module_paths orelse return 0;
    var count: usize = 0;
    for (paths) |path| {
        if (std.mem.indexOf(u8, path, needle) != null) count += 1;
    }
    return count;
}

// ============================================================
// Tree-shaking integration tests
// ============================================================

test {
    _ = @import("tree_shake/cjs.zig");
}

test "TreeShaking: unused side_effects=false module excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts imports only b. c.ts is imported by b but side_effects=false + nobody uses c's exports.
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");
    try writeFile(tmp.dir, "c.ts", "export const dead_code = 'should not appear';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // Bundler를 직접 사용하면 c.ts는 graph에 없음 (a.ts가 import하지 않으므로).
    // tree-shaking은 graph에 있는데 아무도 사용하지 않는 모듈을 제거.
    // 실제 테스트: b.ts가 c.ts를 import하지만 c.ts의 export를 사용하지 않는 경우.
    try writeFile(tmp.dir, "b.ts", "import './c';\nexport const x = 42;");

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // x는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // c.ts는 pure code만 있으므로 auto-pure 감지로 side_effects=false → 제외됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_code") == null);
}

test "TreeShaking: tree_shaking=false preserves all modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1;") != null);
}

test "TreeShaking: entry point exports preserved in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const a = 1;\nexport const b = 2;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 진입점의 모든 export가 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

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

test "TreeShaking: only used exports from dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { used } from './b'; console.log(used);");
    try writeFile(tmp.dir, "b.ts", "export const used = 'yes'; export const unused = 'no';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // used는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
    // unused는 statement-level tree-shaking으로 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no\"") == null);
}

test "TreeShaking: re-export chain dependency included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "TreeShaking: side-effect-only import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './polyfill';\nconst x = 1;");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.myPolyfill = true;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill.ts는 side_effects=true (기본) → 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "myPolyfill") != null);
}

test "TreeShaking: side-effect-only CJS import emits require call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.mjs", "import './cjs.js';\nconsole.log('entry');");
    try writeFile(tmp.dir, "cjs.js", "module.exports = {}; globalThis.cjsSideEffectImport = true;");

    const entry = try absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "cjsSideEffectImport") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjs();") != null);
}

test "TreeShaking: runBeforeMain import-only root preserves side-effect dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "console.log('entry');");
    try writeFile(tmp.dir, "prelude.ts", "import './polyfill';");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.runBeforeMainPolyfill = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const prelude = try absPath(&tmp, "prelude.ts");
    defer std.testing.allocator.free(prelude);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .run_before_main = &.{prelude},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "runBeforeMainPolyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_prelude") != null);
}

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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// package.json sideEffects integration tests
// ============================================================

test "sideEffects: package.json sideEffects=false auto-applied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './node_modules/mypkg/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{"name":"mypkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/mypkg/index.js", "export const x = 1; console.log('should be removed');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "should be removed") == null);
}

test "sideEffects: package.json sideEffects=true keeps module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/polyfill/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/polyfill/package.json",
        \\{"name":"polyfill","sideEffects":true}
    );
    try writeFile(tmp.dir, "node_modules/polyfill/index.js", "globalThis.polyfilled = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "polyfilled") != null);
}

test "sideEffects: no package.json field keeps default true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/nopkg/index.js';");
    try writeFile(tmp.dir, "node_modules/nopkg/package.json",
        \\{"name":"nopkg"}
    );
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "console.log('included');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "included") != null);
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// Integration: real-world patterns
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

test "Integration: lazy barrel skips empty direct re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export { value } from './real';");
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_USED';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips multiple direct re-export sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b } from './barrel';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './a';
        \\export { b } from './b';
    );
    try writeFile(tmp.dir, "a.ts", "export const a = 'LAZY_BARREL_A';");
    try writeFile(tmp.dir, "b.ts", "export const b = 'LAZY_BARREL_B';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips default-as-named direct re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export { default as value } from './real';");
    try writeFile(tmp.dir, "real.ts", "export default 'LAZY_BARREL_DEFAULT';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_DEFAULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips export-star re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "barrel.ts", "export * from './source';");
    try writeFile(tmp.dir, "source.ts",
        \\export function used() { return 'LAZY_BARREL_STAR_USED'; }
        \\export function unused() { return 'LAZY_BARREL_STAR_UNUSED'; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_STAR_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_STAR_UNUSED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips export-star module with unused ambiguous names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { onlyA } from './barrel';
        \\console.log(onlyA);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './a';
        \\export * from './b';
    );
    try writeFile(tmp.dir, "a.ts",
        \\export const onlyA = 'LAZY_BARREL_ONLY_A';
        \\export const shared = 'LAZY_BARREL_SHARED_A';
    );
    try writeFile(tmp.dir, "b.ts",
        \\export const onlyB = 'LAZY_BARREL_ONLY_B';
        \\export const shared = 'LAZY_BARREL_SHARED_B';
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_ONLY_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_ONLY_B") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_SHARED_A") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_SHARED_B") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips local named import re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { value } from './real';
        \\export { value };
    );
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_LOCAL_IMPORT';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_IMPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips local default import re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import value from './real';
        \\export { value };
    );
    try writeFile(tmp.dir, "real.ts", "export default 'LAZY_BARREL_LOCAL_DEFAULT';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_DEFAULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel skips local re-export with explicit extensions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { tsValue } from './barrel.ts';
        \\import { jsValue } from './js-barrel.js';
        \\console.log(tsValue, jsValue);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { tsValue } from './real.ts';
        \\export { tsValue };
    );
    try writeFile(tmp.dir, "real.ts", "export const tsValue = 'LAZY_BARREL_EXPLICIT_TS';");
    try writeFile(tmp.dir, "js-barrel.js",
        \\import { jsValue } from './real.js';
        \\export { jsValue };
    );
    try writeFile(tmp.dir, "real.js", "export const jsValue = 'LAZY_BARREL_EXPLICIT_JS';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_EXPLICIT_TS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_EXPLICIT_JS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "js-barrel.js") == null);
}

test "Integration: lazy barrel skips local re-export with side-effect import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import './side';
        \\import { value } from './real';
        \\export { value };
    );
    try writeFile(tmp.dir, "side.ts", "console.log('LAZY_BARREL_LOCAL_SIDE_EFFECT');");
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_LOCAL_SIDE_VALUE';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_SIDE_EFFECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_SIDE_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
}

test "Integration: lazy barrel does not skip side-effectful re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\console.log('BARREL_SIDE_EFFECT');
        \\export { value } from './real';
    );
    try writeFile(tmp.dir, "real.ts", "export const value = 'SIDE_EFFECT_BARREL_USED';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_EFFECT_BARREL_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "BARREL_SIDE_EFFECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") != null);
}

test "Integration: lazy barrel does not skip namespace re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ns } from './barrel';
        \\console.log(ns.value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export * as ns from './real';");
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_NAMESPACE';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_NAMESPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") != null);
}

test "Integration: lazy barrel does not skip local namespace re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ns } from './barrel';
        \\console.log(ns.value);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import * as ns from './real';
        \\export { ns };
    );
    try writeFile(tmp.dir, "real.ts", "export const value = 'LAZY_BARREL_LOCAL_NAMESPACE';");
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_BARREL_LOCAL_NAMESPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") != null);
}

test "Integration: lazy barrel skips auto-pure package-default re-export module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './barrel';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "barrel.ts", "export { value } from './real';");
    try writeFile(tmp.dir, "real.ts", "export const value = 'PACKAGE_DEFAULT_BARREL';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PACKAGE_DEFAULT_BARREL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "barrel.ts") == null);
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

test "sideEffects: side-effect-only import to ESM module under __esm wrap invokes init (#1193)" {
    // Reanimated `layoutReanimation/index.ts`: `import './animationsManager'` +
    // `export * from './animationBuilder'`. animationsManager.ts는 ESM 모듈이며
    // RN 플랫폼에서 __esm 래핑된다. barrel(index.ts) factory body가 side-effect
    // import 대상의 init 함수를 호출하지 않으면 top-level side-effect가 실행되지
    // 않아 `global.LayoutAnimationsManager` 할당 누락 → UI Hermes SIGABRT.
    //
    // 주의: sideeffect 모듈이 CJS로 감지되면 기존 body rewrite가 require를 호출
    // 하므로 버그가 드러나지 않는다. .ts + export를 포함해 ESM으로 만들어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "pkg/index.ts",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "pkg/values.ts",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "pkg/sideeffect.ts",
        \\export {};
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // side-effect 본문이 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sideEffectRan") != null);

    // barrel(index.ts) init 함수 안에서 sideeffect ESM init이 호출되어야 한다.
    const index_init_start = std.mem.indexOf(u8, result.output, "var init_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    try std.testing.expect(std.mem.indexOf(u8, index_init_block, "init_sideeffect()") != null);
}

test "sideEffects: CJS side-effect import must not be duplicated in barrel init (#1193)" {
    // #1193 fix 후속: CJS 타겟은 body rewrite가 이미 require_xxx()를 주입하므로
    // side-effect import 전용 preamble 루프는 ESM 타겟만 처리해야 한다.
    // 중복 호출은 side-effect가 두 번 실행되는 동작 회귀를 일으킬 수 있음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./sideeffect.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "node_modules/pkg/values.js",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "node_modules/pkg/sideeffect.js",
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const index_init_start = std.mem.indexOf(u8, result.output, "var init_pkg_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    const count = std.mem.count(u8, index_init_block, "require_pkg_sideeffect()");
    try std.testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// UserDefined sideEffects lock — rolldown DeterminedSideEffects::UserDefined parity
// ============================================================

test "sideEffects: UserDefined lock — package.json sideEffects array MUST NOT be overridden by auto-purity" {
    // React-native-worklets의 lib/module/index.js는 top-level에서 init() 호출 (side-effect).
    // 근데 `import` + `function_call()`만 있는 파일은 ZNTC auto-purity 로직이 "pure"로 오판할 수도.
    // package.json의 sideEffects 배열에 명시된 파일은 auto-purity가 덮어쓰면 안 됨.
    // 이 테스트는 해당 regression을 방지한다 (#1193 root cause).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./runtime-init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './runtime-init';
        \\export const x = 1;
    );
    // runtime-init.js는 top-level에서 globalInit() 호출.
    // 호출 자체는 auto-purity 기준으로 "pure"로 보일 수 있지만 (function call on unknown binding),
    // sideEffects array에 명시됐으므로 반드시 보존되어야 한다.
    try writeFile(tmp.dir, "node_modules/pkg/runtime-init.js",
        \\import { globalInit } from './helper';
        \\globalInit();
    );
    try writeFile(tmp.dir, "node_modules/pkg/helper.js",
        \\export function globalInit() { globalThis.__runtimeInitialized = true; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // runtime-init.js body가 번들에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, result.output, "globalInit()") != null);
    // 게다가 top-level init 경로에서 실행 가능해야 한다 — 단순 정의 외에 호출 라인이 있어야 함
    // (RN 플랫폼에서는 __esm wrap의 factory body에 globalInit() 있어야)
    const has_call = std.mem.count(u8, result.output, "globalInit()") >= 2;
    try std.testing.expect(has_call);
}

test "sideEffects: UserDefined lock — sideEffects:false module stays tree-shakable even if complex" {
    // 반대 방향 회귀: sideEffects:false는 auto-purity와 일치 — lock이 잘못 걸리면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/lib';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/lib/package.json",
        \\{"name":"lib","main":"./index.js","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/lib/index.js",
        \\export const x = 1;
        \\export const unused = 2;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1") != null);
}

test "sideEffects: UserDefined lock — auto-purity does not flip package.json true to false" {
    // `sideEffects: true` (array 아님)도 user_defined 설정.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './node_modules/preserve';
    );
    try writeFile(tmp.dir, "node_modules/preserve/package.json",
        \\{"name":"preserve","sideEffects":true}
    );
    // body는 pure literal만 — auto-purity가 보면 "pure"라고 판단할 텍스트.
    try writeFile(tmp.dir, "node_modules/preserve/index.js",
        \\const PURE_CONST = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sideEffects:true로 명시된 순수 module도 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "sideEffects: UserDefined lock — pattern matched file preserved even in node_modules with other pure modules" {
    // react-native-worklets 실제 구조 흉내: sideEffects에 특정 파일만 나열.
    // 매치되는 파일의 top-level call은 보존, 매치 안 되는 pure 파일은 tree-shake.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { api } from './node_modules/worklets';
        \\console.log(api);
    );
    try writeFile(tmp.dir, "node_modules/worklets/package.json",
        \\{"name":"worklets","main":"./index.js","sideEffects":["./index.js","./init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/worklets/index.js",
        \\import { init } from './init';
        \\import { api } from './api';
        \\init();
        \\export { api };
    );
    try writeFile(tmp.dir, "node_modules/worklets/init.js",
        \\export function init() { globalThis.__workletsReady = true; }
    );
    try writeFile(tmp.dir, "node_modules/worklets/api.js",
        \\export const api = 'ok';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // index.js의 `init();` call이 번들에 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init()") != null);
    // api 사용도 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ok\"") != null or
        std.mem.indexOf(u8, result.output, "'ok'") != null);
}

test "TreeShaking: dynamic import target module is preserved (#1260)" {
    // import("./foo") 로만 참조되는 모듈은 정적 import_binding이 없어도
    // 반드시 번들/출력에 포함되어야 한다. 정적 분석에서 제거되면 런타임에 모듈을
    // 찾을 수 없어 깨진다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const m = await import('./lazy');
        \\  return m.unique_lazy_export_token();
        \\}
    );
    try writeFile(tmp.dir, "lazy.ts",
        \\export function unique_lazy_export_token() { return "LAZY_OK_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // lazy.ts의 export가 tree-shake로 제거되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_OK_MARKER") != null);
}

test "TreeShaking: class with impure static field via getter access preserved (#1261)" {
    // esbuild 방식: 클래스가 미참조로 보여도 static field initializer가 impure면 보존.
    // 현재 purity.zig는 static field impurity를 이미 판정하나, 회귀 방지용 테스트.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function sideMarker() { console.log("SIDE_FIELD_INIT"); return 1; }
        \\export class Unused {
        \\  static x = sideMarker();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sideMarker() 호출이 static field로 래핑되어 있어도 side-effect이므로 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_FIELD_INIT") != null);
}

test "TreeShaking: pure static field in unused class is removed (#1261 companion)" {
    // 반대로 pure한 static field만 있는 미사용 class는 제거되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\export class Unused {
        \\  static x = 42;
        \\  static y = "PURE_FIELD_MARKER";
        \\}
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_FIELD_MARKER") == null);
}

test "TreeShaking: dynamic import transitive dependency preserved (#1260 edge)" {
    // import("./lazy") → lazy.ts가 re-export from './deep'인 경우
    // deep.ts의 export도 보존되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const m = await import('./lazy');
        \\  return m.token();
        \\}
    );
    try writeFile(tmp.dir, "lazy.ts", "export { token } from './deep';");
    try writeFile(tmp.dir, "deep.ts",
        \\export function token() { return "DEEP_TRANSITIVE_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEEP_TRANSITIVE_MARKER") != null);
}

test "TreeShaking: dynamic import deep chain (3 levels) preserved (#1260 edge)" {
    // entry -> dyn import a -> static b -> static c — c의 export가 reached
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const a = await import('./a');
        \\  return a.chain();
        \\}
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { fromB } from './b';
        \\export function chain() { return fromB(); }
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { fromC } from './c';
        \\export function fromB() { return fromC(); }
    );
    try writeFile(tmp.dir, "c.ts",
        \\export function fromC() { return "CHAIN_LEVEL3_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CHAIN_LEVEL3_MARKER") != null);
}

test "TreeShaking: dynamic + static import of same module coexist (#1260 edge)" {
    // 동일 모듈이 static import와 dynamic import로 동시 참조될 때
    // 둘 다 올바르게 동작하고 중복 번들되지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { eager } from './shared';
        \\export async function mix() {
        \\  const m = await import('./shared');
        \\  return eager() + m.lazy();
        \\}
    );
    try writeFile(tmp.dir, "shared.ts",
        \\export function eager() { return "EAGER_MARKER"; }
        \\export function lazy() { return "LAZY_MARKER"; }
        \\export function unused() { return "UNUSED_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // dynamic import는 전체 export 보존이므로 unused도 남아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EAGER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_MARKER") != null);
}

test "TreeShaking: dynamic import with non-static specifier does not protect (#1260 edge)" {
    // import(variable) 처럼 정적 해석 불가한 경우 resolved가 none이므로
    // 보호 대상 아님 — 미참조 모듈은 정상적으로 tree-shake되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './a';
        \\declare const name: string;
        \\export async function load() {
        \\  const m = await import(/* non-static */ name as string);
        \\  return (m as any).x;
        \\}
        \\console.log(used());
    );
    try writeFile(tmp.dir, "a.ts", "export function used() { return 'A_USED'; }");
    try writeFile(tmp.dir, "b.ts",
        \\export function unused() { return "B_UNRELATED_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // b.ts는 참조 자체가 없으므로 원래부터 번들에 없음 — 정상 제거 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_UNRELATED_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A_USED") != null);
}

test "TreeShaking: class static block side-effect preserved (#1261 edge)" {
    // static initialization block도 side-effect로 간주되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function marker() { console.log("STATIC_BLOCK_MARKER"); return 1; }
        \\export class Unused {
        \\  static { marker(); }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "STATIC_BLOCK_MARKER") != null);
}

test "TreeShaking: size regression — 1-of-N named imports (#1262)" {
    // 10개 export 중 1개만 import 시 나머지 9개는 제거되어야 한다.
    // 회귀 시 번들 크기가 threshold 초과로 실패.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn5 } from './lib';
        \\console.log(fn5());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function fn0() { return "PAYLOAD_0"; }
        \\export function fn1() { return "PAYLOAD_1"; }
        \\export function fn2() { return "PAYLOAD_2"; }
        \\export function fn3() { return "PAYLOAD_3"; }
        \\export function fn4() { return "PAYLOAD_4"; }
        \\export function fn5() { return "PAYLOAD_5"; }
        \\export function fn6() { return "PAYLOAD_6"; }
        \\export function fn7() { return "PAYLOAD_7"; }
        \\export function fn8() { return "PAYLOAD_8"; }
        \\export function fn9() { return "PAYLOAD_9"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 사용된 fn5만 남고 나머지 9개는 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PAYLOAD_5") != null);
    for ([_][]const u8{ "PAYLOAD_0", "PAYLOAD_1", "PAYLOAD_2", "PAYLOAD_3", "PAYLOAD_4", "PAYLOAD_6", "PAYLOAD_7", "PAYLOAD_8", "PAYLOAD_9" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
}

test "TreeShaking: size regression — deep re-export chain only used exports (#1262)" {
    // barrel → a,b,c → 각각 2개씩 export. entry는 a.used만. 나머지 5개 제거.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_a } from './barrel';
        \\console.log(used_a());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used_a, unused_a } from './a';
        \\export { used_b, unused_b } from './b';
        \\export { used_c, unused_c } from './c';
    );
    try writeFile(tmp.dir, "a.ts",
        \\export function used_a() { return "USED_A_MARKER"; }
        \\export function unused_a() { return "UNUSED_A_MARKER"; }
    );
    try writeFile(tmp.dir, "b.ts",
        \\export function used_b() { return "USED_B_MARKER"; }
        \\export function unused_b() { return "UNUSED_B_MARKER"; }
    );
    try writeFile(tmp.dir, "c.ts",
        \\export function used_c() { return "USED_C_MARKER"; }
        \\export function unused_c() { return "UNUSED_C_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_A_MARKER") != null);
    for ([_][]const u8{ "UNUSED_A_MARKER", "USED_B_MARKER", "UNUSED_B_MARKER", "USED_C_MARKER", "UNUSED_C_MARKER" }) |m| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, m) == null);
    }
}

test "LazyBarrel: sideEffects false named re-export scans only requested source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "node_modules/pkg/a.ts", "export function used() { return 'LAZY_SCAN_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/b.ts", "export function unused() { return 'LAZY_SCAN_UNUSED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.ts\",\"sideEffects\":false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_SCAN_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_SCAN_UNUSED") == null);
    try expectModulePathEnding(&result, "a.ts", true);
    try expectModulePathEnding(&result, "b.ts", false);
}

test "LazyBarrel: import then export default with explicit extension scans requested source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from 'pkg';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.ts",
        \\import value from './real.js';
        \\export { value };
        \\export { unused } from './unused.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/real.js", "export default 'LAZY_IMPORT_EXPORT_DEFAULT';");
    try writeFile(tmp.dir, "node_modules/pkg/unused.js", "export const unused = 'LAZY_IMPORT_EXPORT_UNUSED';");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.ts\",\"sideEffects\":false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_IMPORT_EXPORT_DEFAULT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_IMPORT_EXPORT_UNUSED") == null);
    try expectModulePathEnding(&result, "real.js", true);
    try expectModulePathEnding(&result, "unused.js", false);
}

test "LazyBarrel: default-as-named re-export scans requested source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as unused } from './unused.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'DEFAULT_AS_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused.js", "export default function unused() { return 'DEFAULT_AS_UNUSED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEFAULT_AS_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEFAULT_AS_UNUSED") == null);
    try expectModulePathEnding(&result, "used.js", true);
    try expectModulePathEnding(&result, "unused.js", false);
}

test "LazyBarrel: missing sideEffects field keeps conservative graph scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "node_modules/pkg/a.ts", "export function used() { return 'CONSERVATIVE_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/b.ts", "export function unused() { return 'CONSERVATIVE_UNUSED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.ts\"}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try expectModulePathEnding(&result, "a.ts", true);
    try expectModulePathEnding(&result, "b.ts", true);
}

test "LazyBarrel: sideEffects true and glob matched true keep conservative graph scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used as a } from 'pkgtrue';
        \\import { used as c } from 'pkgglob';
        \\console.log(a(), c());
    );
    try writeFile(tmp.dir, "node_modules/pkgtrue/index.js",
        \\export { used } from './a.js';
        \\export { unused } from './b.js';
    );
    try writeFile(tmp.dir, "node_modules/pkgtrue/a.js", "export function used() { return 'TRUE_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkgtrue/b.js", "export function unused() { return 'TRUE_UNUSED'; }");
    try writeFile(tmp.dir, "node_modules/pkgtrue/package.json", "{\"name\":\"pkgtrue\",\"main\":\"index.js\",\"sideEffects\":true}");
    try writeFile(tmp.dir, "node_modules/pkgglob/index.js",
        \\export { used } from './c.js';
        \\export { unused } from './d.js';
    );
    try writeFile(tmp.dir, "node_modules/pkgglob/c.js", "export function used() { return 'GLOB_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkgglob/d.js", "export function unused() { return 'GLOB_UNUSED'; }");
    try writeFile(tmp.dir, "node_modules/pkgglob/package.json", "{\"name\":\"pkgglob\",\"main\":\"index.js\",\"sideEffects\":[\"./index.js\"]}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try expectModulePathEnding(&result, "node_modules/pkgtrue/a.js", true);
    try expectModulePathEnding(&result, "node_modules/pkgtrue/b.js", true);
    try expectModulePathEnding(&result, "node_modules/pkgglob/c.js", true);
    try expectModulePathEnding(&result, "node_modules/pkgglob/d.js", true);
}

test "LazyBarrel: unused unresolved re-export still reports resolve error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { used } from './used.js';
        \\export { missing } from './missing.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export function used() { return 'UNRESOLVED_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
    var found = false;
    if (result.diagnostics) |diags| {
        for (diags) |d| {
            if (d.code == .unresolved_import and std.mem.indexOf(u8, d.message, "Cannot resolve module") != null) {
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);
    try expectModulePathEnding(&result, "used.js", true);
    try expectModulePathEnding(&result, "missing.js", false);
}

test "LazyBarrel: export star fallback scans only when direct binding is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry-direct.ts",
        \\import { direct } from 'pkg';
        \\console.log(direct());
    );
    try writeFile(tmp.dir, "entry-star.ts",
        \\import { star } from 'pkg';
        \\console.log(star());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { direct } from './direct.js';
        \\export * from './star.js';
        \\export * from './unused-star.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/direct.js", "export function direct() { return 'DIRECT_MARKER'; }");
    try writeFile(tmp.dir, "node_modules/pkg/star.js", "export function star() { return 'STAR_MARKER'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused-star.js", "export function other() { return 'OTHER_STAR_MARKER'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    const entry_direct = try absPath(&tmp, "entry-direct.ts");
    defer std.testing.allocator.free(entry_direct);
    const entry_star = try absPath(&tmp, "entry-star.ts");
    defer std.testing.allocator.free(entry_star);

    var direct_bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry_direct},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer direct_bundler.deinit();
    const direct_result = try direct_bundler.bundle();
    defer direct_result.deinit(std.testing.allocator);

    try std.testing.expect(!direct_result.hasErrors());
    try expectModulePathEnding(&direct_result, "direct.js", true);
    try expectModulePathEnding(&direct_result, "star.js", false);
    try expectModulePathEnding(&direct_result, "unused-star.js", false);

    var star_bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry_star},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer star_bundler.deinit();
    const star_result = try star_bundler.bundle();
    defer star_result.deinit(std.testing.allocator);

    try std.testing.expect(!star_result.hasErrors());
    try expectModulePathEnding(&star_result, "direct.js", false);
    try expectModulePathEnding(&star_result, "star.js", true);
    try expectModulePathEnding(&star_result, "unused-star.js", true);
}

test "LazyBarrel: skipped resolved re-export is not reported unresolved in IIFE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { used } from './used.js';
        \\export { unused } from './unused.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export function used() { return 'IIFE_LAZY_USED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused.js", "export function unused() { return 'IIFE_LAZY_UNUSED'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .format = .iife,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "IIFE_LAZY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "IIFE_LAZY_UNUSED") == null);
    try expectModulePathEnding(&result, "used.js", true);
    try expectModulePathEnding(&result, "unused.js", false);
}

test "LazyBarrel: namespace dynamic side-effect and require consumers scan all sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry-namespace.ts",
        \\import * as ns from 'pkg';
        \\const key = Math.random() > 0.5 ? 'a' : 'b';
        \\console.log(ns[key]);
    );
    try writeFile(tmp.dir, "entry-dynamic.ts",
        \\import('pkg').then((ns) => console.log(ns.a, ns.b));
    );
    try writeFile(tmp.dir, "entry-side-effect.ts",
        \\import 'pkg';
    );
    try writeFile(tmp.dir, "entry-require.ts",
        \\const ns = require('pkg');
        \\console.log(ns.a, ns.b);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { a } from './a.js';
        \\export { b } from './b.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/a.js", "export const a = 'ALL_A_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/b.js", "export const b = 'ALL_B_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    const entries = [_][]const u8{ "entry-namespace.ts", "entry-dynamic.ts", "entry-side-effect.ts", "entry-require.ts" };
    for (entries) |entry_name| {
        const entry = try absPath(&tmp, entry_name);
        defer std.testing.allocator.free(entry);

        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .tree_shaking = true,
            .max_threads = 1,
        });
        defer b.deinit();
        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try expectModulePathEnding(&result, "a.js", true);
        try expectModulePathEnding(&result, "b.js", true);
    }
}

test "LazyBarrel: requested local export conservatively scans all records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { own } from 'pkg';
        \\console.log(own);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const own = 'OWN_MARKER';
        \\export { unused } from './unused.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/unused.js", "export const unused = 'LOCAL_EXPORT_UNUSED';");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OWN_MARKER") != null);
    try expectModulePathEnding(&result, "unused.js", true);
}

test "LazyBarrel: stress 320 sideEffects false re-exports scan three requested sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\import { fn0, fn127, fn319 } from 'pkg';
        \\console.log(fn0(), fn127(), fn319());
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\":\"pkg\",\"main\":\"index.js\",\"sideEffects\":false}");

    var barrel_buf: std.ArrayList(u8) = .empty;
    defer barrel_buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 320) : (i += 1) {
        var line_buf: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "export {{ fn{d} }} from './fn{d}.js';\n", .{ i, i });
        try barrel_buf.appendSlice(std.testing.allocator, line);

        const path = try std.fmt.allocPrint(std.testing.allocator, "node_modules/pkg/fn{d}.js", .{i});
        defer std.testing.allocator.free(path);
        const body = try std.fmt.allocPrint(std.testing.allocator, "export function fn{d}() {{ return 'STRESS_FN_{d}_MARKER'; }}\n", .{ i, i });
        defer std.testing.allocator.free(body);
        try writeFile(tmp.dir, path, body);
    }
    try writeFile(tmp.dir, "node_modules/pkg/index.js", barrel_buf.items);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .max_threads = 1,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "STRESS_FN_0_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "STRESS_FN_127_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "STRESS_FN_319_MARKER") != null);
    try std.testing.expectEqual(@as(usize, 3), countModulePathsContaining(&result, "node_modules/pkg/fn"));
}

test "TreeShaking: export star named import prunes unused source exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "barrel.ts", "export * from './source';");
    try writeFile(tmp.dir, "source.ts",
        \\export function used() { return "USED_STAR_MARKER"; }
        \\export function unused() { return "UNUSED_STAR_MARKER"; }
        \\export function alsoUnused() { return "ALSO_UNUSED_STAR_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_STAR_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_STAR_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ALSO_UNUSED_STAR_MARKER") == null);
}

test "TreeShaking: chained export star named import prunes unrelated sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { leaf } from './top';
        \\console.log(leaf());
    );
    try writeFile(tmp.dir, "top.ts", "export * from './mid'; export * from './other';");
    try writeFile(tmp.dir, "mid.ts", "export * from './leaf';");
    try writeFile(tmp.dir, "leaf.ts",
        \\export function leaf() { return "LIVE_LEAF_MARKER"; }
        \\export function deadLeaf() { return "DEAD_LEAF_MARKER"; }
    );
    try writeFile(tmp.dir, "other.ts",
        \\export function unrelated() { return "UNRELATED_SOURCE_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LIVE_LEAF_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEAD_LEAF_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNRELATED_SOURCE_MARKER") == null);
}

test "TreeShaking: export star named import drops unrelated source declared sideEffects:false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { scaleLinearLike } from './d3';
        \\console.log(scaleLinearLike());
    );
    try writeFile(tmp.dir, "d3.ts",
        \\export * from './scale';
        \\export * from './time-format';
    );
    try writeFile(tmp.dir, "scale.ts",
        \\export function scaleLinearLike() { return "LIVE_SCALE_LINEAR_MARKER"; }
    );
    try writeFile(tmp.dir, "time-format.ts",
        \\export { default as timeFormatDefaultLocale, timeFormat } from './defaultLocale';
    );
    try writeFile(tmp.dir, "defaultLocale.ts",
        \\import { formatLocale } from './locale';
        \\export var timeFormat;
        \\defaultLocale("UNUSED_TIME_FORMAT_DEFAULT_LOCALE_MARKER");
        \\export default function defaultLocale(definition) {
        \\  timeFormat = formatLocale(definition);
        \\  return timeFormat;
        \\}
    );
    try writeFile(tmp.dir, "locale.ts",
        \\import { timeYear } from './time';
        \\export function formatLocale(definition) {
        \\  return definition + timeYear();
        \\}
    );
    try writeFile(tmp.dir, "time.ts",
        \\export function timeYear() { return "UNUSED_D3_TIME_YEAR_MARKER"; }
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LIVE_SCALE_LINEAR_MARKER") != null);
    for ([_][]const u8{
        "UNUSED_TIME_FORMAT_DEFAULT_LOCALE_MARKER",
        "UNUSED_D3_TIME_YEAR_MARKER",
    }) |m| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, m) == null);
    }
}

test "TreeShaking: export star from CJS keeps wrapped source for named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts", "export * from './source.cjs';");
    try writeFile(tmp.dir, "source.cjs",
        \\exports.used = "CJS_STAR_USED_MARKER";
        \\exports.unused = "CJS_STAR_UNUSED_MARKER";
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_STAR_USED_MARKER") != null);
    // CJS wrappers do not have statement-level export precision yet, so this is the remaining
    // conservative fallback that prevents dropping the wrapped source.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_STAR_UNUSED_MARKER") != null);
}

test "TreeShaking: named-only CJS import does not inject __toESM helper cluster" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './source.cjs';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "source.cjs",
        \\exports.used = function() { return "CJS_NAMED_ONLY_USED"; };
        \\exports.unused = function() { return "CJS_NAMED_ONLY_UNUSED"; };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_NAMED_ONLY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_source().used") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__toESM") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__copyProps") == null);
}

test "TreeShaking: unused direct re-export source with local init is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used } from './live';
        \\export { createCustomElement } from './custom-element';
    );
    try writeFile(tmp.dir, "live.ts", "export const used = 'DIRECT_REEXPORT_USED_MARKER';");
    try writeFile(tmp.dir, "legacy.ts",
        \\export function createClassComponent() {
        \\  console.log('DIRECT_REEXPORT_LEGACY_MARKER');
        \\}
    );
    try writeFile(tmp.dir, "custom-element.ts",
        \\import { createClassComponent } from './legacy';
        \\let CustomElement;
        \\if (typeof HTMLElement === 'function') {
        \\  CustomElement = class extends HTMLElement {};
        \\}
        \\export function createCustomElement() {
        \\  console.log('DIRECT_REEXPORT_CUSTOM_MARKER', CustomElement, createClassComponent);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_CUSTOM_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LEGACY_MARKER") == null);
}

test "TreeShaking: unused direct re-export Svelte custom-element fanout is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { mount } from './runtime';
        \\console.log(mount());
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\export { mount } from './client';
        \\export { create_custom_element } from './custom-element';
    );
    try writeFile(tmp.dir, "client.ts",
        \\export function mount() { return 'SVELTE_FANOUT_USED_MOUNT'; }
    );
    try writeFile(tmp.dir, "props.ts",
        \\export function heavyProps() {
        \\  return 'SVELTE_FANOUT_PROPS_HEAVY';
        \\}
    );
    try writeFile(tmp.dir, "legacy-client.ts",
        \\import { heavyProps } from './props';
        \\export function createClassComponent() {
        \\  return 'SVELTE_FANOUT_LEGACY_CLIENT' + heavyProps();
        \\}
    );
    try writeFile(tmp.dir, "custom-element.ts",
        \\import { createClassComponent } from './legacy-client';
        \\let SvelteElement;
        \\if (typeof HTMLElement === 'function') {
        \\  SvelteElement = class extends HTMLElement {
        \\    connectedCallback() {
        \\      createClassComponent();
        \\    }
        \\  };
        \\}
        \\export function create_custom_element() {
        \\  return 'SVELTE_FANOUT_CUSTOM_ELEMENT' + SvelteElement;
        \\}
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_USED_MOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_CUSTOM_ELEMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_LEGACY_CLIENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_PROPS_HEAVY") == null);
}

test "TreeShaking: unused direct re-export source with object literal methods is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './runtime';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\export { used } from './live';
        \\export { prop } from './props';
    );
    try writeFile(tmp.dir, "live.ts", "export function used() { return 'OBJECT_METHOD_REEXPORT_USED'; }");
    try writeFile(tmp.dir, "heavy.ts",
        \\export function heavy() {
        \\  return 'OBJECT_METHOD_REEXPORT_HEAVY';
        \\}
    );
    try writeFile(tmp.dir, "props.ts",
        \\import { heavy } from './heavy';
        \\const rest_props_handler = {
        \\  get(target, key) {
        \\    return target[key];
        \\  },
        \\  set(target, key, value) {
        \\    heavy();
        \\    target[key] = value;
        \\    return true;
        \\  },
        \\  ownKeys(target) {
        \\    return Reflect.ownKeys(target);
        \\  }
        \\};
        \\export function prop(obj, key) {
        \\  return new Proxy(obj, rest_props_handler)[key];
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_REEXPORT_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_REEXPORT_HEAVY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "rest_props_handler") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Reflect.ownKeys") == null);
}

test "TreeShaking: object literal method with impure computed key is preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './side';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "side.ts",
        \\function key() {
        \\  console.log('OBJECT_METHOD_COMPUTED_KEY_EFFECT');
        \\  return 'run';
        \\}
        \\const handler = {
        \\  [key()]() {
        \\    return 1;
        \\  }
        \\};
        \\export const used = 'OBJECT_METHOD_COMPUTED_KEY_USED';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_COMPUTED_KEY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_COMPUTED_KEY_EFFECT") != null);
}

test "TreeShaking: unused pure computed object key initializer is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './computed-key';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "computed-key.ts",
        \\function makeId() {
        \\  return 'COMPUTED_KEY_INIT_SHOULD_DROP';
        \\}
        \\function makeFactory() {
        \\  return makeId();
        \\}
        \\var keySymbol = /* @__PURE__ */ Symbol.for("computed-key-test");
        \\var unusedHolder = { [keySymbol]: makeFactory };
        \\export const used = 'COMPUTED_KEY_USED_MARKER';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPUTED_KEY_USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPUTED_KEY_INIT_SHOULD_DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "makeFactory") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unusedHolder") == null);
}

// minimatch 회귀: TS 가 self-referential 클래스용으로 emit 하는 `var _a; class AST {...}; _a = AST;`
// 패턴에서 후속 비선언 할당이 살아남아야 한다. 도달성 BFS 가 read 만 따르고 writer 엣지를 무시하면
// `_a` 가 undefined 인 채로 클래스 메서드가 `new _a()` 호출 → "_a is not a constructor".
test "TreeShaking: post-declaration assignment to top-level var is preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { make } from './lib';
        \\console.log(make());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\var _self;
        \\class Box {
        \\  static spawn() { return new _self(); }
        \\  tag() { return 'POST_DECL_ASSIGN_TAG'; }
        \\}
        \\_self = Box;
        \\export function make() { return Box.spawn().tag(); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_self = Box") != null);
}

test "TreeShaking: function-body writer of mutable let does not pull function in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { untrack } from './runtime';
        \\console.log(untrack(() => 1));
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\import { HEAVY_DEP_BODY_TAG } from './heavy';
        \\export let untracking = false;
        \\export function untrack(fn) {
        \\  const prev = untracking;
        \\  untracking = true;
        \\  try { return fn(); } finally { untracking = prev; }
        \\}
        \\export function update_reaction() {
        \\  untracking = false;
        \\  return HEAVY_DEP_BODY_TAG;
        \\}
    );
    try writeFile(tmp.dir, "heavy.ts", "export const HEAVY_DEP_BODY_TAG = 'WRITER_OVERFIRE_HEAVY_MARKER';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "untrack") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "update_reaction") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WRITER_OVERFIRE_HEAVY_MARKER") == null);
}

test "TreeShaking: top-level writer kept, function-body writer dropped on shared let" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { read } from './lib';
        \\console.log(read());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\import { HEAVY_DEAD_BODY_TAG } from './heavy';
        \\export let x = 1;
        \\x = 2;
        \\export function read() { return x; }
        \\function dead_fn() { x = 999; return HEAVY_DEAD_BODY_TAG; }
    );
    try writeFile(tmp.dir, "heavy.ts", "export const HEAVY_DEAD_BODY_TAG = 'MIXED_WRITER_HEAVY_MARKER';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_fn") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MIXED_WRITER_HEAVY_MARKER") == null);
}

test "TreeShaking: dead function-body writer does not cascade through transitive imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { readable } from './store';
        \\console.log(readable());
    );
    try writeFile(tmp.dir, "store.ts",
        \\import { untrack } from './runtime';
        \\export function readable() { return untrack(() => 42); }
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\import { effect_helper } from './effects';
        \\export let untracking = false;
        \\export function untrack(fn) {
        \\  const prev = untracking; untracking = true;
        \\  try { return fn(); } finally { untracking = prev; }
        \\}
        \\export function update_effect(e) {
        \\  untracking = false;
        \\  return effect_helper(e);
        \\}
    );
    try writeFile(tmp.dir, "effects.ts",
        \\import { SOURCE_CASCADE_TAG } from './sources';
        \\export function effect_helper(e) { return SOURCE_CASCADE_TAG + e; }
    );
    try writeFile(tmp.dir, "sources.ts", "export const SOURCE_CASCADE_TAG = 'CASCADE_SHOULD_DROP_MARKER';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CASCADE_SHOULD_DROP_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "effect_helper") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "update_effect") == null);
}

test "TreeShaking: compound/update writers inside function body are not writer-edged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { read } from './lib';
        \\console.log(read());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\import { HEAVY_COMPOUND_TAG } from './heavy';
        \\export let counter = 0;
        \\export function read() { return counter; }
        \\function dead_inc() { counter += 1; counter++; return HEAVY_COMPOUND_TAG; }
    );
    try writeFile(tmp.dir, "heavy.ts", "export const HEAVY_COMPOUND_TAG = 'COMPOUND_WRITER_DROP_MARKER';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_inc") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPOUND_WRITER_DROP_MARKER") == null);
}

test "TreeShaking: unused direct re-export source preserves eval side effect only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used } from './live';
        \\export { unused } from './side';
    );
    try writeFile(tmp.dir, "live.ts", "export const used = 'DIRECT_REEXPORT_LIVE_VALUE';");
    try writeFile(tmp.dir, "dep.ts",
        \\console.log('DIRECT_REEXPORT_DEAD_DEP_EVAL');
        \\export function dep() { return 'DIRECT_REEXPORT_DEAD_DEP_BODY'; }
    );
    try writeFile(tmp.dir, "side.ts",
        \\import { dep } from './dep';
        \\console.log('DIRECT_REEXPORT_SIDE_EVAL');
        \\export function unused() {
        \\  console.log('DIRECT_REEXPORT_UNUSED_BODY', dep());
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_SIDE_EVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_UNUSED_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_DEAD_DEP_EVAL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_DEAD_DEP_BODY") == null);
}

test "TreeShaking: side-effect statement import reference keeps direct re-export dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used } from './live';
        \\export { unused } from './side';
    );
    try writeFile(tmp.dir, "live.ts", "export const used = 'DIRECT_REEXPORT_KEEP_LIVE';");
    try writeFile(tmp.dir, "dep.ts",
        \\console.log('DIRECT_REEXPORT_LIVE_DEP_EVAL');
        \\export const dep = 'DIRECT_REEXPORT_LIVE_DEP_VALUE';
        \\export const dead = 'DIRECT_REEXPORT_LIVE_DEP_DEAD';
    );
    try writeFile(tmp.dir, "side.ts",
        \\import { dep } from './dep';
        \\console.log('DIRECT_REEXPORT_SIDE_USES_IMPORT', dep);
        \\export function unused() {
        \\  return 'DIRECT_REEXPORT_SIDE_UNUSED_EXPORT';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_KEEP_LIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_SIDE_USES_IMPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_DEP_EVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_DEP_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_SIDE_UNUSED_EXPORT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_DEP_DEAD") == null);
}

test "TreeShaking: class extends call expression preserved (#1261 edge)" {
    // class Foo extends getBase() — extends call은 side-effect이므로 보존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function getBase() { console.log("EXTENDS_CALL_MARKER"); return class {}; }
        \\export class Unused extends getBase() {}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXTENDS_CALL_MARKER") != null);
}

test "#1291 실제 증상: \"use strict\" + non-simple params 있는 모듈이 graph에서 스킵됨" {
    // 실제 이슈 재현: backend.js 같은 webpack UMD 번들이 내부 함수에
    // `"use strict"` + destructuring params 조합을 가질 때 parser가 validation 에러를
    // 내고 graph.zig가 모듈 전체를 스킵 → require 참조가 생기지만 정의는 없음.
    //
    // SyntaxError지만 V8/Hermes 런타임은 실행하므로 번들러는 경고로 처리해야 함
    // (esbuild/rollup 동일 정책).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\function foo({ a, b }) {
        \\    "use strict";
        \\    return a + b;
        \\}
        \\module.exports = foo;
    );
    try writeFile(tmp.dir, "entry.js",
        \\const foo = require('./lib.js');
        \\console.log(foo({ a: 1, b: 2 }));
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib = __commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = foo") != null);
}

test "TreeShaking: dead statement references don't keep upstream module (#1551)" {
    // svelte/store readable 누수 재현:
    //   entry → barrel의 readable만 사용. barrel 내 unused_fn이 runtime를 참조.
    //   unused_fn은 statement-level DCE로 제거되지만 AST에 참조가 남아
    //   processModuleImports의 reference_count > 0 판정에 의해 runtime이
    //   가짜 used로 마킹되는 문제(#1551). #1558 Step 3+4에서 BFS fixpoint 통합 +
    //   live_mod_idx로 정정 (reachable statement 안의 import만 used로 마킹).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const UPSTREAM_MARKER = "RUNTIME_LEAKED";
        \\export const UPSTREAM_B = "B_LEAKED";
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { UPSTREAM_MARKER, UPSTREAM_B } from './runtime';
        \\export function readable(v: number) { return { value: v }; }
        \\export function unused_fn() {
        \\  return UPSTREAM_MARKER + UPSTREAM_B;
        \\}
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { readable } from './barrel';
        \\console.log(readable(42).value);
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RUNTIME_LEAKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_LEAKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unused_fn") == null);
}

test "TreeShaking: dead statement import chain 2 hops removed (#1551)" {
    // 2-hop 체인: entry → mid. mid는 live export + dead export.
    // dead 함수 안에서만 runtime 참조 — 체인 전체가 제거되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const RUNTIME_TWO_HOP_MARKER = "LEAKED_TWO_HOP";
    );
    try writeFile(tmp.dir, "mid.ts",
        \\import { RUNTIME_TWO_HOP_MARKER } from './runtime';
        \\export function used_mid(n: number) { return n * 2; }
        \\export function dead_mid() { return RUNTIME_TWO_HOP_MARKER; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_mid } from './mid';
        \\console.log(used_mid(21));
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "used_mid") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LEAKED_TWO_HOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_mid") == null);
}

test "TreeShaking: live statement preserves upstream module (#1551 anti-regression)" {
    // 반대 케이스: runtime import가 live 함수에서 참조되면 runtime 모듈은 보존.
    // 보호 모듈 집합(alias 타겟)이 정상 동작하는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const RUNTIME_LIVE = "RUNTIME_STILL_NEEDED";
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { RUNTIME_LIVE } from './runtime';
        \\export function hello() { return RUNTIME_LIVE; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { hello } from './barrel';
        \\console.log(hello());
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RUNTIME_STILL_NEEDED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

// kysely 회귀 #2052: TS interface-only 가 strip 후 빈 `export {}` 만 남고, post-transform
// AST 에서 transformer 가 그 marker 까지 drop 하면 refresh 가 exports_kind 를 `.none` 으로
// 강등 → markEsmCjsHybrid Pass 2 가 implicit CJS 로 승격 → resolveOrCjsFallback 이 첫 번째
// `export *` source 의 빈 CJS wrapper 를 모든 named import 의 source 로 stick 시킴 →
// 실제 정의가 있는 다음 `export *` 는 walk 안 되어 dummy-driver.js 가 tree-shake 된다.
test "TreeShaking: export * chain through TS-stripped empty source still resolves named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Bar } from './barrel';
        \\console.log(new Bar().tag());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './empty';
        \\export * from './real';
    );
    try writeFile(tmp.dir, "empty.ts",
        \\export {};
    );
    try writeFile(tmp.dir, "real.ts",
        \\export class Bar {
        \\  tag() { return 'EXPORT_STAR_CHAIN_KEPT'; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXPORT_STAR_CHAIN_KEPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Bar") != null);
}

// cheerio 회귀 #2051: namespace import (`import * as ns from 'cjslib'`) 의 모든 소비자가
// tree-shake 로 사라졌는데 ImportBinding 자체는 살아 있어 linker 가 `var ns =
// __toESM(require_X(), 1)` 를 emit. 그러나 해당 CJS wrapper 는 모듈 미포함이라 정의되지
// 않아 `require_X is not defined` ReferenceError. preamble emit 도 같이 drop 해야 한다.
test "TreeShaking: namespace import preamble dropped when target excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used());
    );
    // lib.js 가 namespace 로 cjslib 을 import 하지만, 소비자 (`heavy`) 는 entry 에서 안 쓴다.
    try writeFile(tmp.dir, "lib.js",
        \\import * as cjslib from './cjslib.cjs';
        \\export function used() { return 'NS_TARGET_DROP_USED'; }
        \\export function heavy() { return cjslib.bar(); }
    );
    try writeFile(tmp.dir, "cjslib.cjs",
        \\'use strict';
        \\exports.bar = function() { return 'NS_TARGET_DROP_HEAVY'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_USED") != null);
    // heavy() 는 사용 안 하므로 cjslib + 본문 모두 prune 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_HEAVY") == null);
    // `var X = __toESM(require_cjslib_cjs(), 1)` 같은 orphan preamble 이 남으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjslib") == null);
}

test "TreeShaking: CJS default import member access seeds only used export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './react-like.cjs';
        \\console.log(React.createElement());
    );
    try writeFile(tmp.dir, "react-like.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_MEMBER_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_MEMBER_UNUSED'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_MEMBER_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_MEMBER_UNUSED") == null);
}

test "TreeShaking: CJS default import value escape keeps all exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './react-like.cjs';
        \\console.log(typeof React);
    );
    try writeFile(tmp.dir, "react-like.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_ESCAPE_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_ESCAPE_KEPT'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_ESCAPE_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_ESCAPE_KEPT") != null);
}

test "TreeShaking: CJS default member access follows module.exports require proxy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from './index.cjs';
        \\console.log(React.createElement());
    );
    try writeFile(tmp.dir, "index.cjs",
        \\'use strict';
        \\{
        \\  module.exports = require('./react-production.cjs');
        \\}
    );
    try writeFile(tmp.dir, "react-production.cjs",
        \\'use strict';
        \\exports.createElement = function() { return 'CJS_DEFAULT_PROXY_USED'; };
        \\exports.useState = function() { return 'CJS_DEFAULT_PROXY_UNUSED'; };
    );
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_PROXY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CJS_DEFAULT_PROXY_UNUSED") == null);
}

// ============================================================
// #2398 — RN-platform .esm wrap 환경에서 barrel re-export DCE
// ============================================================

test "TreeShaking #2398: RN .esm wrap + sideEffects:false barrel drops unused re-exports" {
    // graph.zig:2510 의 RN preset 이 모든 ESM 모듈을 .esm wrap → 종전엔 lodash-es 처럼
    // 명시적 sideEffects:false 패키지조차 unused re-export 가 전부 번들에 들어가던
    // 회귀. 본 fix 후 user-declared pure 모듈은 정밀 DCE 가능해야 함.
    // findPackageDirPath 가 node_modules 위치 기준이라 fixture 도 동일 구조.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as unused1 } from './unused1.js';
        \\export { default as unused2 } from './unused2.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'USED_FN_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused1.js", "export default function unused1() { return 'UNUSED_FN1_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused2.js", "export default function unused2() { return 'UNUSED_FN2_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FN_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_FN1_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_FN2_BODY") == null);
}

test "TreeShaking #2398: RN .esm wrap + sideEffects 미명시는 conservative 보존 (회귀 가드)" {
    // RN core 처럼 `package.json sideEffects` 필드 없는 모듈은 본 fix 가
    // 종전 보수 동작 유지. user-declared pure 가 아니면 .esm wrap StmtInfo 빌드도
    // 안 하고 evaluation effect 로 간주해 init ordering 깨지지 않도록 안전판.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as helper } from './helper.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'USED_FN'; }");
    try writeFile(tmp.dir, "node_modules/pkg/helper.js", "export default function helper() { return 'HELPER_FN'; }");
    // package.json sideEffects 미명시 (필드 없는 형태) → conservative
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\"}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FN") != null);
    // sideEffects 미명시 → 종전 동작 그대로 helper 도 보존 (보수)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HELPER_FN") != null);
}

test "TreeShaking #2398: RN .esm wrap + sideEffects:false barrel 50개 re-export 스케일" {
    // lodash-es 와 가까운 형태 reproduce. 종전엔 50개 fn body 가 모두 번들에 들어
    // 갔지만 (107KB) 본 fix 후 1 개만 남아야 함. 작은 fixture 에선 발견 안 되던
    // scale-induced 회귀 (예: bitset 크기, O(N²) 폭주) 까지 catch.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // entry — 50개 중 fn0 만 사용
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn0 } from 'pkg';
        \\console.log(fn0());
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    // 50 개 default-as-named re-export 의 barrel — 향후 카운트 늘려도 overflow 없도록 dynamic.
    var barrel_buf: std.ArrayList(u8) = .empty;
    defer barrel_buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "export {{ default as fn{d} }} from './fn{d}.js';\n", .{ i, i });
        try barrel_buf.appendSlice(std.testing.allocator, line);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "node_modules/pkg/fn{d}.js", .{i});
        var body_buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "export default function fn{d}() {{ return 'FN_BODY_{d}_MARKER'; }}\n", .{ i, i });
        try writeFile(tmp.dir, name, body);
    }
    try writeFile(tmp.dir, "node_modules/pkg/index.js", barrel_buf.items);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "FN_BODY_0_MARKER") != null);
    // 49개 unused 모두 drop 검증 (n=1..49)
    var j: usize = 1;
    while (j < 50) : (j += 1) {
        var marker_buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "FN_BODY_{d}_MARKER", .{j});
        try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
}

test "TreeShaking #2398: RN .esm wrap + side-effect import 는 본문 보존" {
    // sideEffects 패턴 매칭으로 setup.js 만 side_effects=true 인 케이스. setup.js 가
    // evaluation effect 로 잡혀 보존되어야 함. metadata.zig:438 의 새 `continue` 가드가
    // legitimate init 호출까지 끊지 않는지 회귀 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { val } from 'pkg';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './setup.js';
        \\export { val } from './val.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/setup.js", "globalThis.__SETUP_RAN__ = 'SIDE_EFFECT_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/val.js", "export const val = 'VAL_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": [\"./setup.js\"]}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VAL_MARKER") != null);
    // setup.js 는 sideEffects pattern 매칭 → 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_EFFECT_MARKER") != null);
}

test "TreeShaking #2398: RN require() 가 .esm wrap target namespace 전체 보존" {
    // markAllExportsUsed 가 .cjs 뿐 아니라 .esm wrap target 에도 적용되는지 검증.
    // 본 fix 전에는 .esm 의 StmtInfo 부재로 자동 보존됐던 동작인데, 본 fix 가
    // StmtInfo 빌드를 활성화하면서 명시 마킹 필요. 빠지면 require() 결과 객체의
    // 일부 property 가 undefined 가 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lib = require('pkg');
        \\console.log(lib.a, lib.b, lib.c);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const a = 'A_MARKER';
        \\export const b = 'B_MARKER';
        \\export const c = 'C_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require() namespace 접근 → 모든 export 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "C_MARKER") != null);
}

test "TreeShaking #2398: RN namespace import (`import * as ns`) 가 .esm wrap pure pkg 의 모든 export 보존" {
    // require() 와 대칭 — `import * as ns` 도 어떤 property 가 읽힐지 정적 분석 불가
    // 하므로 namespace 사용 시 모든 export 가 살아야 함. tree_shaker 의 namespace 경로
    // (registerNamespaceRewrites 등) 가 .esm wrap 에도 markAllExportsUsed 적용해야
    // 일부 property 가 undefined 가 되는 회귀 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as ns from 'pkg';
        \\const key = (Math.random() > 0.5) ? 'a' : 'b';
        \\console.log(ns[key], ns.c);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const a = 'NS_A_MARKER';
        \\export const b = 'NS_B_MARKER';
        \\export const c = 'NS_C_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace 객체로 사용 → static analysis 불가능 → 보수적으로 모두 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_A_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_B_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_C_MARKER") != null);
}
