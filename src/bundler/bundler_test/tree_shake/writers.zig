const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking writer and assignment liveness tests
// ============================================================

// minimatch regression: TS emits `var _a; class AST {...}; _a = AST;` for
// self-referential classes, so the post-declaration assignment must stay live.
// If reachability follows reads but ignores writer edges, `_a` remains undefined.

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

test "TreeShaking: unused worklet metadata assignments do not keep pure modules live" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './node_modules/worklet-pkg/lib';
        \\console.log('WORKLET_METADATA_ENTRY');
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/package.json",
        \\{"name":"worklet-pkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/lib.ts",
        \\export {};
        \\class ReanimatedError extends Error {}
        \\function validateAnimatedStyles(styles) {
        \\  if (typeof styles !== 'object') throw new ReanimatedError('bad');
        \\}
        \\validateAnimatedStyles.__workletHash = 4291796598;
        \\validateAnimatedStyles.__closure = {
        \\  ReanimatedError,
        \\  ReanimatedError__classFactory: ReanimatedError.classFactory,
        \\};
        \\validateAnimatedStyles.__initData = { code: 'function validateAnimatedStyles(){}' };
        \\validateAnimatedStyles.__stackDetails = [new global.Error(), -3, -27];
        \\validateAnimatedStyles.__pluginVersion = '0.7.2';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WORKLET_METADATA_ENTRY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "validateAnimatedStyles") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__workletHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ReanimatedError") == null);
}

test "TreeShaking: unused worklet metadata assignments are dropped when sibling exports stay live" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { useAnimatedStyle } from './node_modules/worklet-pkg/useAnimatedStyle';
        \\console.log(useAnimatedStyle({ onFrame: true }));
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/package.json",
        \\{"name":"worklet-pkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/utils.ts",
        \\class ReanimatedError extends Error {}
        \\export function isAnimated(prop) {
        \\  return !!prop.onFrame;
        \\}
        \\isAnimated.__workletHash = 125899194;
        \\isAnimated.__closure = {};
        \\export function shallowEqual(a, b) {
        \\  return Object.keys(a).length === Object.keys(b).length;
        \\}
        \\shallowEqual.__workletHash = 125899195;
        \\shallowEqual.__closure = {};
        \\export function validateAnimatedStyles(styles) {
        \\  throw new ReanimatedError('VALIDATE_ANIMATED_STYLES_MARKER');
        \\}
        \\validateAnimatedStyles.__workletHash = 4291796598;
        \\validateAnimatedStyles.__closure = {
        \\  ReanimatedError,
        \\  ReanimatedError__classFactory: ReanimatedError.classFactory,
        \\};
        \\validateAnimatedStyles.__initData = { code: 'function validateAnimatedStyles(){}' };
        \\validateAnimatedStyles.__stackDetails = [new global.Error(), -3, -27];
        \\validateAnimatedStyles.__pluginVersion = '0.7.2';
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/useAnimatedStyle.ts",
        \\import { isAnimated, shallowEqual, validateAnimatedStyles } from './utils';
        \\export function useAnimatedStyle(style) {
        \\  if (__DEV__) {
        \\    validateAnimatedStyles(style);
        \\  }
        \\  return isAnimated(style) && shallowEqual({ a: 1 }, { a: 1 });
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .platform = .react_native,
        .define = &.{.{ .key = "__DEV__", .value = "false" }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "onFrame") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "shallowEqual") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "validateAnimatedStyles") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "4291796598") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VALIDATE_ANIMATED_STYLES_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ReanimatedError") == null);
}

test "TreeShaking: native worklet transform does not leave metadata for dead dev-only export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { useAnimatedStyle } from './node_modules/worklet-pkg/useAnimatedStyle';
        \\console.log(useAnimatedStyle({ onFrame: true }));
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/package.json",
        \\{"name":"worklet-pkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/utils.ts",
        \\class ReanimatedError extends Error {}
        \\export function isAnimated(prop) {
        \\  'worklet';
        \\  return !!prop.onFrame;
        \\}
        \\export function shallowEqual(a, b) {
        \\  'worklet';
        \\  return Object.keys(a).length === Object.keys(b).length;
        \\}
        \\export function validateAnimatedStyles(styles) {
        \\  'worklet';
        \\  throw new ReanimatedError('VALIDATE_ANIMATED_STYLES_MARKER');
        \\}
    );
    try writeFile(tmp.dir, "node_modules/worklet-pkg/useAnimatedStyle.ts",
        \\import { isAnimated, shallowEqual, validateAnimatedStyles } from './utils';
        \\export function useAnimatedStyle(style) {
        \\  if (__DEV__) {
        \\    validateAnimatedStyles(style);
        \\  }
        \\  return isAnimated(style) && shallowEqual({ a: 1 }, { a: 1 });
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .platform = .react_native,
        .worklet_transform = true,
        .define = &.{.{ .key = "__DEV__", .value = "false" }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "onFrame") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "validateAnimatedStyles") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VALIDATE_ANIMATED_STYLES_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ReanimatedError") == null);
}
