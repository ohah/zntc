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
