const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

test "TreeShaking CJS: named import prunes unused Object.defineProperty exports value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function used() { return "USED_DEFINE_PROPERTY_MARKER"; }
        \\function unused() { return "UNUSED_DEFINE_PROPERTY_MARKER"; }
        \\Object.defineProperty(exports, "used", { value: used, enumerable: true });
        \\Object.defineProperty(exports, "unused", { "value": unused, enumerable: true });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DEFINE_PROPERTY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_DEFINE_PROPERTY_MARKER") == null);
}

test "TreeShaking CJS: module.exports defineProperty keeps helper and require target" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\const helper = require("./helper.js");
        \\function used() { return helper("USED_DEFINE_REQUIRE_TARGET_MARKER"); }
        \\function unusedPrivate() { return "UNUSED_DEFINE_PRIVATE_MARKER"; }
        \\Object.defineProperty(module.exports, "used", { value: used });
        \\Object.defineProperty(module.exports, "unused", { value: unusedPrivate });
    );
    try writeFile(tmp.dir, "helper.js",
        \\function helper(value) { return value; }
        \\module.exports = helper;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DEFINE_REQUIRE_TARGET_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_DEFINE_PRIVATE_MARKER") == null);
}

test "TreeShaking CJS: named import prunes unused Object.defineProperty member value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\const liveNs = { value: function used() { return "USED_DEFINE_MEMBER_MARKER"; } };
        \\const deadNs = { value: function unused() { return "UNUSED_DEFINE_MEMBER_MARKER"; } };
        \\Object.defineProperty(exports, "used", { value: liveNs.value, enumerable: true });
        \\Object.defineProperty(exports, "unused", { value: deadNs.value, enumerable: true });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DEFINE_MEMBER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_DEFINE_MEMBER_MARKER") == null);
}

test "TreeShaking CJS: named import prunes safe __esModule defineProperty marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\function used() { return "USED_ESMODULE_MARKER"; }
        \\function unused() { return "UNUSED_ESMODULE_MARKER"; }
        \\Object.defineProperty(exports, "used", { value: used });
        \\Object.defineProperty(exports, "unused", { value: unused });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_ESMODULE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esModule") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_ESMODULE_MARKER") == null);
}

test "TreeShaking CJS: named import prunes safe module.exports __esModule marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\Object.defineProperty(module.exports, "__esModule", { value: true });
        \\function used() { return "USED_MODULE_EXPORTS_ESMODULE_MARKER"; }
        \\function unused() { return "UNUSED_MODULE_EXPORTS_ESMODULE_MARKER"; }
        \\Object.defineProperty(module.exports, "used", { value: used });
        \\Object.defineProperty(module.exports, "unused", { value: unused });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_MODULE_EXPORTS_ESMODULE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esModule") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_MODULE_EXPORTS_ESMODULE_MARKER") == null);
}

test "TreeShaking CJS: named import keeps sibling side effects while pruning safe __esModule marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used);");
    try writeFile(tmp.dir, "lib.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\console.log("USED_SIDE_EFFECT_ESMODULE_MARKER");
        \\exports.used = "USED_SIDE_EFFECT_EXPORT_MARKER";
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_SIDE_EFFECT_ESMODULE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_SIDE_EFFECT_EXPORT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esModule") == null);
}

test "TreeShaking CJS: default import keeps __esModule defineProperty marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import value from './lib.js'; console.log(value());");
    try writeFile(tmp.dir, "lib.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = function usedDefault() { return "USED_DEFAULT_ESMODULE_MARKER"; };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DEFAULT_ESMODULE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esModule") != null);
}

test "TreeShaking CJS: unsafe Object.defineProperty export forms are preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function used() { return "USED_DEFINE_UNSAFE_MARKER"; }
        \\function unused() { return "UNSAFE_DEFINE_UNUSED_FN_MARKER"; }
        \\function sideEffect() { console.log("UNSAFE_DEFINE_EFFECT_MARKER"); return unused; }
        \\const define = Object.defineProperty;
        \\const e = exports;
        \\const key = "computed";
        \\const extra = { enumerable: true };
        \\const ns = { unused };
        \\const marker = true;
        \\Object.defineProperty(exports, "__esModule", { value: marker });
        \\Object.defineProperty(exports, "used", { value: used });
        \\Object.defineProperty(exports, "getter", { get() { return "UNSAFE_DEFINE_GETTER_MARKER"; } });
        \\Object.defineProperty(exports, "effect", { value: sideEffect() });
        \\Object.defineProperty(exports, key, { value: unused });
        \\Object.defineProperty(exports, 123, { value: unused });
        \\Object.defineProperty(exports, "dup", { value: used, value: unused });
        \\Object.defineProperty(exports, "spread", { value: unused, ...extra });
        \\Object.defineProperty(exports, "computedDescriptor", { ["value"]: unused });
        \\Object.defineProperty(exports, "member", { value: ns.unused });
        \\Object.defineProperty(e, "targetAlias", { value: unused });
        \\Object["defineProperty"](exports, "computedCallee", { value: unused });
        \\Object.defineProperty(exports, "extraArg", { value: unused }, extra);
        \\Object.defineProperty(exports, "u\\x73ed", { value: unused });
        \\define(exports, "alias", { value: unused });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DEFINE_UNSAFE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esModule") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_DEFINE_UNUSED_FN_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_DEFINE_EFFECT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_DEFINE_GETTER_MARKER") != null);
}
