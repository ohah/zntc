const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking CJS: default member access prunes, namespace and export star keep all static exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "default.js", "import lib from './lib.js'; console.log(lib.used);");
    try writeFile(tmp.dir, "namespace.js", "import * as lib from './lib.js'; console.log(lib.used);");
    try writeFile(tmp.dir, "star-entry.js", "import { used } from './barrel.js'; console.log(used);");
    try writeFile(tmp.dir, "barrel.js", "export * from './lib.js';");
    try writeFile(tmp.dir, "lib.js",
        \\exports.used = "CJS_USED";
        \\exports.unused = "CJS_UNUSED_MUST_STAY";
    );

    const default_entry = try absPath(&tmp, "default.js");
    defer std.testing.allocator.free(default_entry);
    const namespace_entry = try absPath(&tmp, "namespace.js");
    defer std.testing.allocator.free(namespace_entry);
    const star_entry = try absPath(&tmp, "star-entry.js");
    defer std.testing.allocator.free(star_entry);

    var b_default = Bundler.init(std.testing.allocator, .{ .entry_points = &.{default_entry} });
    defer b_default.deinit();
    const default_result = try b_default.bundle(std.testing.io);
    defer default_result.deinit(std.testing.allocator);
    try std.testing.expect(!default_result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, default_result.output, "CJS_UNUSED_MUST_STAY") == null);

    var b_namespace = Bundler.init(std.testing.allocator, .{ .entry_points = &.{namespace_entry} });
    defer b_namespace.deinit();
    const namespace_result = try b_namespace.bundle(std.testing.io);
    defer namespace_result.deinit(std.testing.allocator);
    try std.testing.expect(!namespace_result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, namespace_result.output, "CJS_UNUSED_MUST_STAY") != null);

    var b_star = Bundler.init(std.testing.allocator, .{ .entry_points = &.{star_entry} });
    defer b_star.deinit();
    const star_result = try b_star.bundle(std.testing.io);
    defer star_result.deinit(std.testing.allocator);
    try std.testing.expect(!star_result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, star_result.output, "CJS_UNUSED_MUST_STAY") != null);
}

test "TreeShaking CJS: dynamic export patterns and effectful RHS are preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used);");
    try writeFile(tmp.dir, "lib.js",
        \\function sideEffect() { console.log("EFFECTFUL_UNUSED_MARKER"); return 1; }
        \\const key = "computed";
        \\exports.used = "USED_DYNAMIC_CASE";
        \\exports.unused = sideEffect();
        \\exports[key] = "COMPUTED_MUST_STAY";
        \\Object.defineProperty(exports, "getter", { get() { return "GETTER_MUST_STAY"; } });
        \\module.exports = { used: exports.used, objectUnused: "OBJECT_MUST_STAY" };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DYNAMIC_CASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EFFECTFUL_UNUSED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPUTED_MUST_STAY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "GETTER_MUST_STAY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_MUST_STAY") != null);
}

test "TreeShaking CJS: live export keeps CJS require target evaluation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\const helper = require("./helper.js");
        \\function used() { return helper("USED_REQUIRE_TARGET_MARKER"); }
        \\function unused() { return "UNUSED_REQUIRE_EXPORT_MARKER"; }
        \\exports.used = used;
        \\exports.unused = unused;
    );
    try writeFile(tmp.dir, "helper.js",
        \\function helper(value) { return value; }
        \\module.exports = helper;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_REQUIRE_TARGET_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_REQUIRE_EXPORT_MARKER") == null);
}
