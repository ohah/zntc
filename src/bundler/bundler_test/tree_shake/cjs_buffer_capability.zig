const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
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
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = buffer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MODULE_EXPORTS_BUFFER_UNUSED_MARKER") == null);
}
