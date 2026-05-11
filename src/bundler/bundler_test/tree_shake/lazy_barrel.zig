const std = @import("std");
const bundler_mod = @import("../../bundler.zig");
const Bundler = bundler_mod.Bundler;
const BundleResult = bundler_mod.BundleResult;
const test_helpers = @import("../../test_helpers.zig");
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
// Lazy barrel tree-shaking tests
// ============================================================

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
