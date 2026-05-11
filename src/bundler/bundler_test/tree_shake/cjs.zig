const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking CJS export pruning tests
// ============================================================

test "TreeShaking CJS: named import prunes unused exports dot assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function used() { return "USED_MARKER"; }
        \\function unused() { return "UNUSED_EXPORT_MARKER"; }
        \\exports.used = used;
        \\exports.unused = unused;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_EXPORT_MARKER") == null);
}

test "TreeShaking CJS: named import prunes unused module exports dot assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function used() { return "USED_MODULE_EXPORT_MARKER"; }
        \\function unused() { return "UNUSED_MODULE_EXPORT_MARKER"; }
        \\module.exports.used = used;
        \\module.exports.unused = unused;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_MODULE_EXPORT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_MODULE_EXPORT_MARKER") == null);
}

test "TreeShaking CJS: used export keeps helper but unused private body is removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function helper() { return "HELPER_MARKER"; }
        \\function used() { return helper(); }
        \\function unusedPrivate() { return "UNUSED_PRIVATE_MARKER"; }
        \\exports.used = used;
        \\exports.unused = unusedPrivate;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HELPER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_PRIVATE_MARKER") == null);
}

test "TreeShaking CJS: node Buffer capability branch prunes safe-buffer fallback body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(Buffer.alloc(4).length);");
    try writeFile(tmp.dir, "lib.js",
        \\var buffer = require("buffer");
        \\var Buffer = buffer.Buffer;
        \\function copyProps(src, dst) {
        \\  for (var key in src) dst[key] = src[key];
        \\}
        \\if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) {
        \\  module.exports = buffer;
        \\} else {
        \\  copyProps(buffer, exports);
        \\  exports.Buffer = SafeBuffer;
        \\}
        \\function SafeBuffer(arg, encodingOrOffset, length) {
        \\  return Buffer(arg, encodingOrOffset, length);
        \\}
        \\SafeBuffer.prototype = Object.create(Buffer.prototype);
        \\copyProps(Buffer, SafeBuffer);
        \\SafeBuffer.from = function(arg, encodingOrOffset, length) {
        \\  if (typeof arg === "number") throw new TypeError("SAFE_BUFFER_FALLBACK_MARKER");
        \\  return Buffer(arg, encodingOrOffset, length);
        \\};
        \\SafeBuffer.allocUnsafeSlow = function(size) {
        \\  return buffer.SlowBuffer(size);
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SAFE_BUFFER_FALLBACK_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "allocUnsafeSlow") == null);
}

test "TreeShaking CJS: unknown Buffer-like capability branch preserves fallback body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(typeof Buffer);");
    try writeFile(tmp.dir, "lib.js",
        \\var buffer = getRuntimeBuffer();
        \\var Buffer = buffer.Buffer;
        \\function getRuntimeBuffer() {
        \\  return globalThis.runtimeBuffer;
        \\}
        \\if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) {
        \\  module.exports = buffer;
        \\} else {
        \\  exports.Buffer = SafeBuffer;
        \\}
        \\function SafeBuffer() {
        \\  return "UNKNOWN_BUFFER_FALLBACK_MARKER";
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNKNOWN_BUFFER_FALLBACK_MARKER") != null);
}

test "TreeShaking CJS: node:buffer capability branch is treated like buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(Buffer.from('x').length);");
    try writeFile(tmp.dir, "lib.js",
        \\var buffer = require("node:buffer");
        \\var Buffer = buffer.Buffer;
        \\if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) {
        \\  module.exports = buffer;
        \\} else {
        \\  exports.Buffer = SafeBuffer;
        \\}
        \\function SafeBuffer() {
        \\  return "NODE_PREFIX_FALLBACK_MARKER";
        \\}
        \\SafeBuffer.from = function() {
        \\  return "NODE_PREFIX_SETUP_MARKER";
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NODE_PREFIX_FALLBACK_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NODE_PREFIX_SETUP_MARKER") == null);
}

test "TreeShaking CJS: incomplete Buffer capability check does not prune fallback body" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(typeof Buffer);");
    try writeFile(tmp.dir, "lib.js",
        \\var buffer = require("buffer");
        \\var Buffer = buffer.Buffer;
        \\if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe) {
        \\  module.exports = buffer;
        \\} else {
        \\  exports.Buffer = SafeBuffer;
        \\}
        \\function SafeBuffer() {
        \\  return "INCOMPLETE_CAPABILITY_FALLBACK_MARKER";
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "INCOMPLETE_CAPABILITY_FALLBACK_MARKER") != null);
}

test "TreeShaking CJS: browser platform does not apply Node Buffer capability fact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(typeof Buffer);");
    try writeFile(tmp.dir, "lib.js",
        \\var buffer = require("buffer");
        \\var Buffer = buffer.Buffer;
        \\if (Buffer.from && Buffer.alloc && Buffer.allocUnsafe && Buffer.allocUnsafeSlow) {
        \\  module.exports = buffer;
        \\} else {
        \\  exports.Buffer = SafeBuffer;
        \\}
        \\function SafeBuffer() {
        \\  return "BROWSER_PLATFORM_FALLBACK_MARKER";
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "BROWSER_PLATFORM_FALLBACK_MARKER") != null);
}

test "TreeShaking CJS: named Buffer import seeds module.exports buffer assignment without exports fact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { Buffer } from './lib.js'; console.log(Buffer.alloc(1).length);");
    try writeFile(tmp.dir, "lib.js",
        \\var buffer = require("buffer");
        \\module.exports = buffer;
        \\function unusedFallback() {
        \\  return "MODULE_EXPORTS_BUFFER_UNUSED_MARKER";
        \\}
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_EXPORTS_BUFFER_UNUSED_MARKER") == null);
}

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
    const default_result = try b_default.bundle();
    defer default_result.deinit(std.testing.allocator);
    try std.testing.expect(!default_result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, default_result.output, "CJS_UNUSED_MUST_STAY") == null);

    var b_namespace = Bundler.init(std.testing.allocator, .{ .entry_points = &.{namespace_entry} });
    defer b_namespace.deinit();
    const namespace_result = try b_namespace.bundle();
    defer namespace_result.deinit(std.testing.allocator);
    try std.testing.expect(!namespace_result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, namespace_result.output, "CJS_UNUSED_MUST_STAY") != null);

    var b_star = Bundler.init(std.testing.allocator, .{ .entry_points = &.{star_entry} });
    defer b_star.deinit();
    const star_result = try b_star.bundle();
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
    const result = try b.bundle();
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
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_REQUIRE_TARGET_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_REQUIRE_EXPORT_MARKER") == null);
}

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

test "TreeShaking CJS: module.exports object escape-key matches decoded named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function liveImpl() { return "USED_OBJECT_ESCAPE_MARKER"; }
        \\function deadImpl() { return "UNUSED_OBJECT_ESCAPE_MARKER"; }
        \\module.exports = { "u\x73ed": liveImpl, dead: deadImpl };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_OBJECT_ESCAPE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_OBJECT_ESCAPE_MARKER") == null);
}

test "TreeShaking CJS: module.exports duplicate escape-key preserves last-wins runtime value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function earlyImpl() { return "EARLY_DUP_KEY_MARKER"; }
        \\function lateImpl() { return "LATE_DUP_KEY_MARKER"; }
        \\module.exports = { used: earlyImpl, "u\x73ed": lateImpl };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 런타임 시맨틱: object literal duplicate key 는 last-wins → module.exports.used === lateImpl.
    // 정적 prune 이 디코드된 이름 충돌을 인식하지 못하면 earlyImpl 만 살리고 lateImpl 을 dead 로
    // 잘못 prune 한다 (correctness 버그). 안전한 동작은 충돌을 보수적으로 opaque 처리해
    // lateImpl 의 body 가 보존되는 것.
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LATE_DUP_KEY_MARKER") != null);
}

test "TreeShaking CJS: Object.defineProperty escape export name matches decoded named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function liveImpl() { return "USED_DEFINE_ESCAPE_MARKER"; }
        \\function deadImpl() { return "UNUSED_DEFINE_ESCAPE_MARKER"; }
        \\Object.defineProperty(exports, "u\x73ed", { value: liveImpl });
        \\Object.defineProperty(exports, "dead", { value: deadImpl });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_DEFINE_ESCAPE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_DEFINE_ESCAPE_MARKER") == null);
}

test "TreeShaking CJS: duplicate defineProperty export facts are preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function earlyImpl() { return "EARLY_DEFINE_DUP_MARKER"; }
        \\function lateImpl() { return "LATE_DEFINE_DUP_MARKER"; }
        \\Object.defineProperty(exports, "used", { value: earlyImpl, configurable: true });
        \\Object.defineProperty(exports, "u\x73ed", { value: lateImpl, configurable: true });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LATE_DEFINE_DUP_MARKER") != null);
}

test "TreeShaking CJS: cross-kind duplicate export facts are preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function earlyImpl() { return "EARLY_CROSS_DUP_MARKER"; }
        \\function lateImpl() { return "LATE_CROSS_DUP_MARKER"; }
        \\exports.used = earlyImpl;
        \\Object.defineProperty(exports, "u\x73ed", { value: lateImpl, configurable: true });
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LATE_CROSS_DUP_MARKER") != null);
}

test "TreeShaking CJS: named import prunes module.exports object shorthand property" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function used() { return "USED_OBJECT_SHORTHAND_MARKER"; }
        \\function unused() { return "UNUSED_OBJECT_SHORTHAND_MARKER"; }
        \\module.exports = { used, unused };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_OBJECT_SHORTHAND_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_OBJECT_SHORTHAND_MARKER") == null);
}

test "TreeShaking CJS: named import prunes module.exports object explicit and string properties" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used, alias } from './lib.js'; console.log(used(), alias());");
    try writeFile(tmp.dir, "lib.js",
        \\function usedImpl() { return "USED_OBJECT_EXPLICIT_MARKER"; }
        \\function aliasImpl() { return "USED_OBJECT_STRING_KEY_MARKER"; }
        \\function unusedImpl() { return "UNUSED_OBJECT_EXPLICIT_MARKER"; }
        \\module.exports = { used: usedImpl, "alias": aliasImpl, unused: unusedImpl };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_OBJECT_EXPLICIT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_OBJECT_STRING_KEY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_OBJECT_EXPLICIT_MARKER") == null);
}

test "TreeShaking CJS: module.exports object keeps used helper and removes unused private declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\function helper() { return "OBJECT_HELPER_MARKER"; }
        \\function used() { return helper(); }
        \\function unusedPrivate() { return "OBJECT_UNUSED_PRIVATE_MARKER"; }
        \\module.exports = { used, unused: unusedPrivate };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_HELPER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_UNUSED_PRIVATE_MARKER") == null);
}

test "TreeShaking CJS: named import prunes module.exports object static member value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\const liveNs = { value: function used() { return "USED_OBJECT_MEMBER_VALUE_MARKER"; } };
        \\const deadNs = { value: function unused() { return "UNUSED_OBJECT_MEMBER_VALUE_MARKER"; } };
        \\module.exports = { used: liveNs.value, unused: deadNs.value };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_OBJECT_MEMBER_VALUE_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_OBJECT_MEMBER_VALUE_MARKER") == null);
}

test "TreeShaking CJS: unsafe module.exports object shapes are preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used);");
    try writeFile(tmp.dir, "lib.js",
        \\function unused() { return "UNSAFE_OBJECT_UNUSED_FN_MARKER"; }
        \\function sideEffect() { console.log("UNSAFE_OBJECT_EFFECT_MARKER"); return unused; }
        \\const key = "computed";
        \\const extra = { spread: unused };
        \\const used = "UNSAFE_OBJECT_USED_MARKER";
        \\module.exports = {
        \\  used,
        \\  [key]: unused,
        \\  ...extra,
        \\  get getter() { return "UNSAFE_OBJECT_GETTER_MARKER"; },
        \\  method() { return "UNSAFE_OBJECT_METHOD_MARKER"; },
        \\  effect: sideEffect(),
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_OBJECT_USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_OBJECT_UNUSED_FN_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_OBJECT_EFFECT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_OBJECT_GETTER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNSAFE_OBJECT_METHOD_MARKER") != null);
}

test "TreeShaking CJS: module.exports object live export keeps require target evaluation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\const helper = require("./helper.js");
        \\function used() { return helper("USED_OBJECT_REQUIRE_TARGET_MARKER"); }
        \\function unused() { return "UNUSED_OBJECT_REQUIRE_EXPORT_MARKER"; }
        \\module.exports = { used, unused };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_OBJECT_REQUIRE_TARGET_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_OBJECT_REQUIRE_EXPORT_MARKER") == null);
}

test "TreeShaking CJS: ES5 target preserves transformer-injected runtime helper module" {
    // Regression: transformer 가 graph parse 단계에서 inject 한 runtime helper import
    // (예: `import { __read } from "\x00zntc:runtime/read"`) 는 semantic scope_maps 에
    // 등록되지 않아 cjs-wrap 모듈에서 isImportLiveInModule 가 항상 false 를 반환했다.
    // 결과: helper module 이 included 안 되어 dist 의 `__read` 호출이 정의를 못 찾아
    // ReferenceError (semver@es5 smoke 회귀).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import lib from './lib.cjs'; console.log(lib.foo([1,2]));");
    try writeFile(tmp.dir, "lib.cjs",
        \\module.exports = {
        \\  foo: function(arr) {
        \\    var [a, b] = arr;
        \\    return a + b;
        \\  },
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = .{ .destructuring = true },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __read 호출이 emit 됐다면 정의도 함께 dist 에 있어야 한다.
    if (std.mem.indexOf(u8, result.output, "__read(") != null) {
        try std.testing.expect(std.mem.indexOf(u8, result.output, "var __read") != null or
            std.mem.indexOf(u8, result.output, "function __read") != null);
    }
}
