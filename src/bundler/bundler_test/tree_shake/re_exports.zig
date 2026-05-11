const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking export-star and direct re-export tests
// ============================================================

comptime {
    _ = @import("direct_re_exports.zig");
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
