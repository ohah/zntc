const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking CJS export pruning tests
// ============================================================

test {
    _ = @import("cjs_buffer_capability.zig");
    _ = @import("cjs_interop.zig");
    _ = @import("cjs_define_property.zig");
    _ = @import("cjs_object_exports.zig");
}

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

test "TreeShaking CJS: react_native named import keeps used exports dot assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { used } from './lib.js'; console.log(used());");
    try writeFile(tmp.dir, "lib.js",
        \\'use strict';
        \\var used = () => "RN_USED_MARKER";
        \\var unused = () => "RN_UNUSED_EXPORT_MARKER";
        \\exports.used = used;
        \\exports.unused = unused;
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RN_USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.used = used") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RN_UNUSED_EXPORT_MARKER") == null);
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
