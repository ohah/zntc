const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

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
