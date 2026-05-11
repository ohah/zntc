const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Integration: lazy barrel real-world patterns
// ============================================================

comptime {
    _ = @import("integration_core.zig");
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
