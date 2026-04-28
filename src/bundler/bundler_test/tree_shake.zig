const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking integration tests
// ============================================================

test "TreeShaking: unused side_effects=false module excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts imports only b. c.ts is imported by b but side_effects=false + nobody uses c's exports.
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");
    try writeFile(tmp.dir, "c.ts", "export const dead_code = 'should not appear';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    // Bundler를 직접 사용하면 c.ts는 graph에 없음 (a.ts가 import하지 않으므로).
    // tree-shaking은 graph에 있는데 아무도 사용하지 않는 모듈을 제거.
    // 실제 테스트: b.ts가 c.ts를 import하지만 c.ts의 export를 사용하지 않는 경우.
    try writeFile(tmp.dir, "b.ts", "import './c';\nexport const x = 42;");

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // x는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // c.ts는 pure code만 있으므로 auto-pure 감지로 side_effects=false → 제외됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_code") == null);
}

test "TreeShaking: tree_shaking=false preserves all modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1;") != null);
}

test "TreeShaking: entry point exports preserved in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const a = 1;\nexport const b = 2;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 진입점의 모든 export가 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

test "TreeShaking: only used exports from dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { used } from './b'; console.log(used);");
    try writeFile(tmp.dir, "b.ts", "export const used = 'yes'; export const unused = 'no';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // used는 출력에 존재
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
    // unused는 statement-level tree-shaking으로 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no\"") == null);
}

test "TreeShaking: re-export chain dependency included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "TreeShaking: side-effect-only import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './polyfill';\nconst x = 1;");
    try writeFile(tmp.dir, "polyfill.ts", "globalThis.myPolyfill = true;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill.ts는 side_effects=true (기본) → 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "myPolyfill") != null);
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

test "TreeShaking CJS: default namespace and export star keep all static exports" {
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
    try std.testing.expect(std.mem.indexOf(u8, default_result.output, "CJS_UNUSED_MUST_STAY") != null);

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
        \\Object.defineProperty(exports, "__esModule", { value: true });
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
    // (예: `import { __read } from "\x00zts:runtime/read"`) 는 semantic scope_maps 에
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

// ============================================================
// @__PURE__ annotation tests
// ============================================================

test "@__PURE__: annotation preserved in call expression output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: annotation preserved with #__PURE__ syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* #__PURE__ */ bar();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: annotation on new expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ new Foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__PURE__: no annotation when not present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@__PURE__") == null);
}

test "@__PURE__: annotation not emitted in minify mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ foo();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify_whitespace = true, .minify_identifiers = true, .minify_syntax = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "@__PURE__") == null);
}

test "@__PURE__: applies to first call only in chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // /* @__PURE__ */ a().b() → @__PURE__는 a()에만, b()에는 적용 안 됨
    try writeFile(tmp.dir, "index.ts", "const x = /* @__PURE__ */ a().b();");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // @__PURE__가 정확히 1번만 출력
    const output = result.output;
    const first = std.mem.indexOf(u8, output, "/* @__PURE__ */");
    try std.testing.expect(first != null);
    // 두 번째가 없어야 함
    if (first) |pos| {
        try std.testing.expect(std.mem.indexOf(u8, output[pos + 15 ..], "/* @__PURE__ */") == null);
    }
}

test "@__PURE__: preserved across modules in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { create } from './b'; const x = /* @__PURE__ */ create();");
    try writeFile(tmp.dir, "b.ts", "export function create() { return {}; }");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// package.json sideEffects integration tests
// ============================================================

test "sideEffects: package.json sideEffects=false auto-applied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './node_modules/mypkg/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{"name":"mypkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/mypkg/index.js", "export const x = 1; console.log('should be removed');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "should be removed") == null);
}

test "sideEffects: package.json sideEffects=true keeps module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/polyfill/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/polyfill/package.json",
        \\{"name":"polyfill","sideEffects":true}
    );
    try writeFile(tmp.dir, "node_modules/polyfill/index.js", "globalThis.polyfilled = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "polyfilled") != null);
}

test "sideEffects: no package.json field keeps default true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/nopkg/index.js';");
    try writeFile(tmp.dir, "node_modules/nopkg/package.json",
        \\{"name":"nopkg"}
    );
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "console.log('included');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "included") != null);
}

// ============================================================
// @__NO_SIDE_EFFECTS__ tests
// ============================================================

test "@__NO_SIDE_EFFECTS__: function flag preserved in bundle output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // @__NO_SIDE_EFFECTS__ 함수를 import해서 호출
    try writeFile(tmp.dir, "entry.ts",
        \\import { create } from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function create") != null);
    // cross-module @__NO_SIDE_EFFECTS__ 전파: import한 함수의 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: call to annotated function auto-pure in single file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ function create() { return {}; }
        \\const x = create();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // create() 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: function expression variant" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\const make = /* @__NO_SIDE_EFFECTS__ */ function() { return {}; };
        \\const x = make();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // make() 호출에 /* @__PURE__ */ 자동 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: cross-module re-export chain" {
    // a.ts → b.ts (re-export) → c.ts (원본 @__NO_SIDE_EFFECTS__)
    // a.ts에서 호출 시 /* @__PURE__ */ 출력되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { create } from './re-export';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "re-export.ts", "export { create } from './lib';");
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: cross-module multiple imports" {
    // 여러 함수 중 하나만 @__NO_SIDE_EFFECTS__ — 해당 호출만 pure
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { pure, impure } from './lib';
        \\const a = pure();
        \\const b = impure();
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ export function pure() { return 1; }
        \\export function impure() { return 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // pure() 호출에만 /* @__PURE__ */ 출력
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
    // /* @__PURE__ */ 는 1번만 나와야 함 (impure() 호출에는 없음)
    const first = std.mem.indexOf(u8, result.output, "/* @__PURE__ */").?;
    const second = std.mem.indexOf(u8, result.output[first + 1 ..], "/* @__PURE__ */");
    try std.testing.expect(second == null);
}

test "@__NO_SIDE_EFFECTS__: cross-module default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import create from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export default function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: no false positive on normal import" {
    // @__NO_SIDE_EFFECTS__ 없는 함수는 pure 마킹 안 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { normal } from './lib';
        \\const x = normal();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "export function normal() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // /* @__PURE__ */ 가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") == null);
}

test "@__NO_SIDE_EFFECTS__: export default async function" {
    // async 키워드가 @__NO_SIDE_EFFECTS__ 전파를 끊지 않는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import create from './lib';
        \\const x = create();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export default async function create() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: export async function (named)" {
    // export async function도 @__NO_SIDE_EFFECTS__ 전파됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchData } from './lib';
        \\const x = fetchData();
        \\console.log(x);
    );
    try writeFile(tmp.dir, "lib.ts", "/* @__NO_SIDE_EFFECTS__ */ export async function fetchData() { return {}; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

test "@__NO_SIDE_EFFECTS__: single-file async function" {
    // 단일 파일에서도 async function @__NO_SIDE_EFFECTS__ 동작 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\/* @__NO_SIDE_EFFECTS__ */ async function create() { return {}; }
        \\const x = create();
        \\console.log(x);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "/* @__PURE__ */") != null);
}

// ============================================================
// Integration: real-world patterns
// ============================================================

test "Integration: barrel file tree-shaking with sideEffects=false" {
    // barrel index에서 하나만 import → sideEffects=false면 미사용 모듈 제거
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "barrel/a.ts", "export const used = 'a';");
    try writeFile(tmp.dir, "barrel/b.ts", "export const unused = 'b';");
    try writeFile(tmp.dir, "barrel/package.json", "{\"sideEffects\": false}");

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
    // used가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    // sideEffects=false이므로 b.ts가 미사용 → 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"b\"") == null);
}

test "Integration: barrel file without sideEffects keeps all" {
    // sideEffects 필드 없으면 보수적으로 전부 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "lib/index.ts",
        \\export { used } from './a';
        \\export { unused } from './b';
    );
    try writeFile(tmp.dir, "lib/a.ts", "export const used = 'a';");
    try writeFile(tmp.dir, "lib/b.ts",
        \\console.log('b side effect');
        \\export const unused = 'b';
    );

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"a\"") != null);
    // sideEffects 없으므로 b.ts의 side effect 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "b side effect") != null);
}

test "Integration: diamond re-export resolves to same symbol" {
    // 같은 원본 symbol을 두 경로로 import → 선언이 한 번만 존재해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { shared as a } from './path-a';
        \\import { shared as b } from './path-b';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "path-a.ts", "export { shared } from './original';");
    try writeFile(tmp.dir, "path-b.ts", "export { shared } from './original';");
    try writeFile(tmp.dir, "original.ts", "export const shared = 'original';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared 선언이 한 번만 존재해야 함 (중복 불가)
    const first = std.mem.indexOf(u8, result.output, "\"original\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, result.output[first + 1 ..], "\"original\"") == null);
}

test "Integration: class extends across module boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Derived } from './derived';
        \\const d = new Derived();
        \\console.log(d.greet());
    );
    try writeFile(tmp.dir, "derived.ts",
        \\import { Base } from './base';
        \\export class Derived extends Base {
        \\  greet() { return super.greet() + ' world'; }
        \\}
    );
    try writeFile(tmp.dir, "base.ts",
        \\export class Base {
        \\  greet() { return 'hello'; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // scope hoisting 후에도 extends Base 참조가 유효해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "extends Base") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Base") != null);
    // Base가 Derived보다 먼저 선언 (exec_index 순)
    const base_pos = std.mem.indexOf(u8, result.output, "class Base") orelse return error.TestUnexpectedResult;
    const derived_pos = std.mem.indexOf(u8, result.output, "class Derived") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_pos < derived_pos);
}

test "Integration: default and named re-export combined" {
    // default + named를 re-export하고 import — lodash-es/rxjs 패턴
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import theDefault, { named } from './re-export';
        \\console.log(theDefault, named);
    );
    try writeFile(tmp.dir, "re-export.ts", "export { default, named } from './lib';");
    try writeFile(tmp.dir, "lib.ts",
        \\export default function lib() { return 'default'; }
        \\export const named = 'named';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named\"") != null);
}

test "Integration: side-effect order with export star" {
    // export * 순서가 원본 import 순서와 일치해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { util } from './barrel';
        \\console.log(util);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './init';
        \\export * from './utils';
    );
    try writeFile(tmp.dir, "init.ts",
        \\console.log('1-init');
        \\export const init = true;
    );
    try writeFile(tmp.dir, "utils.ts",
        \\console.log('2-utils');
        \\export const util = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // init.ts가 utils.ts보다 먼저 실행 (import 순서)
    const init_pos = std.mem.indexOf(u8, result.output, "1-init") orelse return error.TestUnexpectedResult;
    const utils_pos = std.mem.indexOf(u8, result.output, "2-utils") orelse return error.TestUnexpectedResult;
    try std.testing.expect(init_pos < utils_pos);
}

test "Integration: deeply nested barrel re-exports" {
    // 3단 barrel: entry → barrel1 → barrel2 → lib
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { deep } from './barrel1';
        \\console.log(deep);
    );
    try writeFile(tmp.dir, "barrel1.ts", "export { deep } from './barrel2';");
    try writeFile(tmp.dir, "barrel2.ts", "export { deep } from './lib';");
    try writeFile(tmp.dir, "lib.ts", "export const deep = 'found';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"found\"") != null);
}

test "Integration: mixed default/named import from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import App, { version, config } from './app';
        \\console.log(App, version, config);
    );
    try writeFile(tmp.dir, "app.ts",
        \\export default class App { name = 'app'; }
        \\export const version = '1.0';
        \\export const config = { debug: true };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class App") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "debug") != null);
}

test "sideEffects: side-effect-only import to ESM module under __esm wrap invokes init (#1193)" {
    // Reanimated `layoutReanimation/index.ts`: `import './animationsManager'` +
    // `export * from './animationBuilder'`. animationsManager.ts는 ESM 모듈이며
    // RN 플랫폼에서 __esm 래핑된다. barrel(index.ts) factory body가 side-effect
    // import 대상의 init 함수를 호출하지 않으면 top-level side-effect가 실행되지
    // 않아 `global.LayoutAnimationsManager` 할당 누락 → UI Hermes SIGABRT.
    //
    // 주의: sideeffect 모듈이 CJS로 감지되면 기존 body rewrite가 require를 호출
    // 하므로 버그가 드러나지 않는다. .ts + export를 포함해 ESM으로 만들어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "pkg/index.ts",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "pkg/values.ts",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "pkg/sideeffect.ts",
        \\export {};
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // side-effect 본문이 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sideEffectRan") != null);

    // barrel(index.ts) init 함수 안에서 sideeffect ESM init이 호출되어야 한다.
    const index_init_start = std.mem.indexOf(u8, result.output, "var init_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    try std.testing.expect(std.mem.indexOf(u8, index_init_block, "init_sideeffect()") != null);
}

test "sideEffects: CJS side-effect import must not be duplicated in barrel init (#1193)" {
    // #1193 fix 후속: CJS 타겟은 body rewrite가 이미 require_xxx()를 주입하므로
    // side-effect import 전용 preamble 루프는 ESM 타겟만 처리해야 한다.
    // 중복 호출은 side-effect가 두 번 실행되는 동작 회귀를 일으킬 수 있음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./sideeffect.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "node_modules/pkg/values.js",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "node_modules/pkg/sideeffect.js",
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const index_init_start = std.mem.indexOf(u8, result.output, "var init_pkg_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    const count = std.mem.count(u8, index_init_block, "require_pkg_sideeffect()");
    try std.testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// UserDefined sideEffects lock — rolldown DeterminedSideEffects::UserDefined parity
// ============================================================

test "sideEffects: UserDefined lock — package.json sideEffects array MUST NOT be overridden by auto-purity" {
    // React-native-worklets의 lib/module/index.js는 top-level에서 init() 호출 (side-effect).
    // 근데 `import` + `function_call()`만 있는 파일은 ZTS auto-purity 로직이 "pure"로 오판할 수도.
    // package.json의 sideEffects 배열에 명시된 파일은 auto-purity가 덮어쓰면 안 됨.
    // 이 테스트는 해당 regression을 방지한다 (#1193 root cause).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./runtime-init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './runtime-init';
        \\export const x = 1;
    );
    // runtime-init.js는 top-level에서 globalInit() 호출.
    // 호출 자체는 auto-purity 기준으로 "pure"로 보일 수 있지만 (function call on unknown binding),
    // sideEffects array에 명시됐으므로 반드시 보존되어야 한다.
    try writeFile(tmp.dir, "node_modules/pkg/runtime-init.js",
        \\import { globalInit } from './helper';
        \\globalInit();
    );
    try writeFile(tmp.dir, "node_modules/pkg/helper.js",
        \\export function globalInit() { globalThis.__runtimeInitialized = true; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // runtime-init.js body가 번들에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, result.output, "globalInit()") != null);
    // 게다가 top-level init 경로에서 실행 가능해야 한다 — 단순 정의 외에 호출 라인이 있어야 함
    // (RN 플랫폼에서는 __esm wrap의 factory body에 globalInit() 있어야)
    const has_call = std.mem.count(u8, result.output, "globalInit()") >= 2;
    try std.testing.expect(has_call);
}

test "sideEffects: UserDefined lock — sideEffects:false module stays tree-shakable even if complex" {
    // 반대 방향 회귀: sideEffects:false는 auto-purity와 일치 — lock이 잘못 걸리면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/lib';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/lib/package.json",
        \\{"name":"lib","main":"./index.js","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/lib/index.js",
        \\export const x = 1;
        \\export const unused = 2;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1") != null);
}

test "sideEffects: UserDefined lock — auto-purity does not flip package.json true to false" {
    // `sideEffects: true` (array 아님)도 user_defined 설정.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './node_modules/preserve';
    );
    try writeFile(tmp.dir, "node_modules/preserve/package.json",
        \\{"name":"preserve","sideEffects":true}
    );
    // body는 pure literal만 — auto-purity가 보면 "pure"라고 판단할 텍스트.
    try writeFile(tmp.dir, "node_modules/preserve/index.js",
        \\const PURE_CONST = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sideEffects:true로 명시된 순수 module도 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "sideEffects: UserDefined lock — pattern matched file preserved even in node_modules with other pure modules" {
    // react-native-worklets 실제 구조 흉내: sideEffects에 특정 파일만 나열.
    // 매치되는 파일의 top-level call은 보존, 매치 안 되는 pure 파일은 tree-shake.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { api } from './node_modules/worklets';
        \\console.log(api);
    );
    try writeFile(tmp.dir, "node_modules/worklets/package.json",
        \\{"name":"worklets","main":"./index.js","sideEffects":["./index.js","./init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/worklets/index.js",
        \\import { init } from './init';
        \\import { api } from './api';
        \\init();
        \\export { api };
    );
    try writeFile(tmp.dir, "node_modules/worklets/init.js",
        \\export function init() { globalThis.__workletsReady = true; }
    );
    try writeFile(tmp.dir, "node_modules/worklets/api.js",
        \\export const api = 'ok';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // index.js의 `init();` call이 번들에 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init()") != null);
    // api 사용도 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ok\"") != null or
        std.mem.indexOf(u8, result.output, "'ok'") != null);
}

test "TreeShaking: dynamic import target module is preserved (#1260)" {
    // import("./foo") 로만 참조되는 모듈은 정적 import_binding이 없어도
    // 반드시 번들/출력에 포함되어야 한다. 정적 분석에서 제거되면 런타임에 모듈을
    // 찾을 수 없어 깨진다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const m = await import('./lazy');
        \\  return m.unique_lazy_export_token();
        \\}
    );
    try writeFile(tmp.dir, "lazy.ts",
        \\export function unique_lazy_export_token() { return "LAZY_OK_MARKER"; }
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
    // lazy.ts의 export가 tree-shake로 제거되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_OK_MARKER") != null);
}

test "TreeShaking: class with impure static field via getter access preserved (#1261)" {
    // esbuild 방식: 클래스가 미참조로 보여도 static field initializer가 impure면 보존.
    // 현재 purity.zig는 static field impurity를 이미 판정하나, 회귀 방지용 테스트.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function sideMarker() { console.log("SIDE_FIELD_INIT"); return 1; }
        \\export class Unused {
        \\  static x = sideMarker();
        \\}
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
    // sideMarker() 호출이 static field로 래핑되어 있어도 side-effect이므로 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_FIELD_INIT") != null);
}

test "TreeShaking: pure static field in unused class is removed (#1261 companion)" {
    // 반대로 pure한 static field만 있는 미사용 class는 제거되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\export class Unused {
        \\  static x = 42;
        \\  static y = "PURE_FIELD_MARKER";
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PURE_FIELD_MARKER") == null);
}

test "TreeShaking: dynamic import transitive dependency preserved (#1260 edge)" {
    // import("./lazy") → lazy.ts가 re-export from './deep'인 경우
    // deep.ts의 export도 보존되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const m = await import('./lazy');
        \\  return m.token();
        \\}
    );
    try writeFile(tmp.dir, "lazy.ts", "export { token } from './deep';");
    try writeFile(tmp.dir, "deep.ts",
        \\export function token() { return "DEEP_TRANSITIVE_MARKER"; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEEP_TRANSITIVE_MARKER") != null);
}

test "TreeShaking: dynamic import deep chain (3 levels) preserved (#1260 edge)" {
    // entry -> dyn import a -> static b -> static c — c의 export가 reached
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function load() {
        \\  const a = await import('./a');
        \\  return a.chain();
        \\}
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { fromB } from './b';
        \\export function chain() { return fromB(); }
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { fromC } from './c';
        \\export function fromB() { return fromC(); }
    );
    try writeFile(tmp.dir, "c.ts",
        \\export function fromC() { return "CHAIN_LEVEL3_MARKER"; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CHAIN_LEVEL3_MARKER") != null);
}

test "TreeShaking: dynamic + static import of same module coexist (#1260 edge)" {
    // 동일 모듈이 static import와 dynamic import로 동시 참조될 때
    // 둘 다 올바르게 동작하고 중복 번들되지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { eager } from './shared';
        \\export async function mix() {
        \\  const m = await import('./shared');
        \\  return eager() + m.lazy();
        \\}
    );
    try writeFile(tmp.dir, "shared.ts",
        \\export function eager() { return "EAGER_MARKER"; }
        \\export function lazy() { return "LAZY_MARKER"; }
        \\export function unused() { return "UNUSED_MARKER"; }
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
    // dynamic import는 전체 export 보존이므로 unused도 남아야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EAGER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LAZY_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_MARKER") != null);
}

test "TreeShaking: dynamic import with non-static specifier does not protect (#1260 edge)" {
    // import(variable) 처럼 정적 해석 불가한 경우 resolved가 none이므로
    // 보호 대상 아님 — 미참조 모듈은 정상적으로 tree-shake되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './a';
        \\declare const name: string;
        \\export async function load() {
        \\  const m = await import(/* non-static */ name as string);
        \\  return (m as any).x;
        \\}
        \\console.log(used());
    );
    try writeFile(tmp.dir, "a.ts", "export function used() { return 'A_USED'; }");
    try writeFile(tmp.dir, "b.ts",
        \\export function unused() { return "B_UNRELATED_MARKER"; }
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
    // b.ts는 참조 자체가 없으므로 원래부터 번들에 없음 — 정상 제거 확인
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_UNRELATED_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A_USED") != null);
}

test "TreeShaking: class static block side-effect preserved (#1261 edge)" {
    // static initialization block도 side-effect로 간주되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function marker() { console.log("STATIC_BLOCK_MARKER"); return 1; }
        \\export class Unused {
        \\  static { marker(); }
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "STATIC_BLOCK_MARKER") != null);
}

test "TreeShaking: size regression — 1-of-N named imports (#1262)" {
    // 10개 export 중 1개만 import 시 나머지 9개는 제거되어야 한다.
    // 회귀 시 번들 크기가 threshold 초과로 실패.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn5 } from './lib';
        \\console.log(fn5());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function fn0() { return "PAYLOAD_0"; }
        \\export function fn1() { return "PAYLOAD_1"; }
        \\export function fn2() { return "PAYLOAD_2"; }
        \\export function fn3() { return "PAYLOAD_3"; }
        \\export function fn4() { return "PAYLOAD_4"; }
        \\export function fn5() { return "PAYLOAD_5"; }
        \\export function fn6() { return "PAYLOAD_6"; }
        \\export function fn7() { return "PAYLOAD_7"; }
        \\export function fn8() { return "PAYLOAD_8"; }
        \\export function fn9() { return "PAYLOAD_9"; }
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
    // 사용된 fn5만 남고 나머지 9개는 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "PAYLOAD_5") != null);
    for ([_][]const u8{ "PAYLOAD_0", "PAYLOAD_1", "PAYLOAD_2", "PAYLOAD_3", "PAYLOAD_4", "PAYLOAD_6", "PAYLOAD_7", "PAYLOAD_8", "PAYLOAD_9" }) |marker| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
}

test "TreeShaking: size regression — deep re-export chain only used exports (#1262)" {
    // barrel → a,b,c → 각각 2개씩 export. entry는 a.used만. 나머지 5개 제거.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_a } from './barrel';
        \\console.log(used_a());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used_a, unused_a } from './a';
        \\export { used_b, unused_b } from './b';
        \\export { used_c, unused_c } from './c';
    );
    try writeFile(tmp.dir, "a.ts",
        \\export function used_a() { return "USED_A_MARKER"; }
        \\export function unused_a() { return "UNUSED_A_MARKER"; }
    );
    try writeFile(tmp.dir, "b.ts",
        \\export function used_b() { return "USED_B_MARKER"; }
        \\export function unused_b() { return "UNUSED_B_MARKER"; }
    );
    try writeFile(tmp.dir, "c.ts",
        \\export function used_c() { return "USED_C_MARKER"; }
        \\export function unused_c() { return "UNUSED_C_MARKER"; }
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_A_MARKER") != null);
    for ([_][]const u8{ "UNUSED_A_MARKER", "USED_B_MARKER", "UNUSED_B_MARKER", "USED_C_MARKER", "UNUSED_C_MARKER" }) |m| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, m) == null);
    }
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

test "TreeShaking: unused direct re-export source with local init is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used } from './live';
        \\export { createCustomElement } from './custom-element';
    );
    try writeFile(tmp.dir, "live.ts", "export const used = 'DIRECT_REEXPORT_USED_MARKER';");
    try writeFile(tmp.dir, "legacy.ts",
        \\export function createClassComponent() {
        \\  console.log('DIRECT_REEXPORT_LEGACY_MARKER');
        \\}
    );
    try writeFile(tmp.dir, "custom-element.ts",
        \\import { createClassComponent } from './legacy';
        \\let CustomElement;
        \\if (typeof HTMLElement === 'function') {
        \\  CustomElement = class extends HTMLElement {};
        \\}
        \\export function createCustomElement() {
        \\  console.log('DIRECT_REEXPORT_CUSTOM_MARKER', CustomElement, createClassComponent);
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_CUSTOM_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LEGACY_MARKER") == null);
}

test "TreeShaking: unused direct re-export Svelte custom-element fanout is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { mount } from './runtime';
        \\console.log(mount());
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\export { mount } from './client';
        \\export { create_custom_element } from './custom-element';
    );
    try writeFile(tmp.dir, "client.ts",
        \\export function mount() { return 'SVELTE_FANOUT_USED_MOUNT'; }
    );
    try writeFile(tmp.dir, "props.ts",
        \\export function heavyProps() {
        \\  return 'SVELTE_FANOUT_PROPS_HEAVY';
        \\}
    );
    try writeFile(tmp.dir, "legacy-client.ts",
        \\import { heavyProps } from './props';
        \\export function createClassComponent() {
        \\  return 'SVELTE_FANOUT_LEGACY_CLIENT' + heavyProps();
        \\}
    );
    try writeFile(tmp.dir, "custom-element.ts",
        \\import { createClassComponent } from './legacy-client';
        \\let SvelteElement;
        \\if (typeof HTMLElement === 'function') {
        \\  SvelteElement = class extends HTMLElement {
        \\    connectedCallback() {
        \\      createClassComponent();
        \\    }
        \\  };
        \\}
        \\export function create_custom_element() {
        \\  return 'SVELTE_FANOUT_CUSTOM_ELEMENT' + SvelteElement;
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_USED_MOUNT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_CUSTOM_ELEMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_LEGACY_CLIENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SVELTE_FANOUT_PROPS_HEAVY") == null);
}

test "TreeShaking: unused direct re-export source with object literal methods is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './runtime';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "runtime.ts",
        \\export { used } from './live';
        \\export { prop } from './props';
    );
    try writeFile(tmp.dir, "live.ts", "export function used() { return 'OBJECT_METHOD_REEXPORT_USED'; }");
    try writeFile(tmp.dir, "heavy.ts",
        \\export function heavy() {
        \\  return 'OBJECT_METHOD_REEXPORT_HEAVY';
        \\}
    );
    try writeFile(tmp.dir, "props.ts",
        \\import { heavy } from './heavy';
        \\const rest_props_handler = {
        \\  get(target, key) {
        \\    return target[key];
        \\  },
        \\  set(target, key, value) {
        \\    heavy();
        \\    target[key] = value;
        \\    return true;
        \\  },
        \\  ownKeys(target) {
        \\    return Reflect.ownKeys(target);
        \\  }
        \\};
        \\export function prop(obj, key) {
        \\  return new Proxy(obj, rest_props_handler)[key];
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_REEXPORT_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_REEXPORT_HEAVY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "rest_props_handler") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Reflect.ownKeys") == null);
}

test "TreeShaking: object literal method with impure computed key is preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './side';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "side.ts",
        \\function key() {
        \\  console.log('OBJECT_METHOD_COMPUTED_KEY_EFFECT');
        \\  return 'run';
        \\}
        \\const handler = {
        \\  [key()]() {
        \\    return 1;
        \\  }
        \\};
        \\export const used = 'OBJECT_METHOD_COMPUTED_KEY_USED';
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_COMPUTED_KEY_USED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "OBJECT_METHOD_COMPUTED_KEY_EFFECT") != null);
}

// minimatch 회귀: TS 가 self-referential 클래스용으로 emit 하는 `var _a; class AST {...}; _a = AST;`
// 패턴에서 후속 비선언 할당이 살아남아야 한다. 도달성 BFS 가 read 만 따르고 writer 엣지를 무시하면
// `_a` 가 undefined 인 채로 클래스 메서드가 `new _a()` 호출 → "_a is not a constructor".
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

test "TreeShaking: unused direct re-export source preserves eval side effect only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used } from './live';
        \\export { unused } from './side';
    );
    try writeFile(tmp.dir, "live.ts", "export const used = 'DIRECT_REEXPORT_LIVE_VALUE';");
    try writeFile(tmp.dir, "dep.ts",
        \\console.log('DIRECT_REEXPORT_DEAD_DEP_EVAL');
        \\export function dep() { return 'DIRECT_REEXPORT_DEAD_DEP_BODY'; }
    );
    try writeFile(tmp.dir, "side.ts",
        \\import { dep } from './dep';
        \\console.log('DIRECT_REEXPORT_SIDE_EVAL');
        \\export function unused() {
        \\  console.log('DIRECT_REEXPORT_UNUSED_BODY', dep());
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_SIDE_EVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_UNUSED_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_DEAD_DEP_EVAL") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_DEAD_DEP_BODY") == null);
}

test "TreeShaking: side-effect statement import reference keeps direct re-export dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './barrel';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { used } from './live';
        \\export { unused } from './side';
    );
    try writeFile(tmp.dir, "live.ts", "export const used = 'DIRECT_REEXPORT_KEEP_LIVE';");
    try writeFile(tmp.dir, "dep.ts",
        \\console.log('DIRECT_REEXPORT_LIVE_DEP_EVAL');
        \\export const dep = 'DIRECT_REEXPORT_LIVE_DEP_VALUE';
        \\export const dead = 'DIRECT_REEXPORT_LIVE_DEP_DEAD';
    );
    try writeFile(tmp.dir, "side.ts",
        \\import { dep } from './dep';
        \\console.log('DIRECT_REEXPORT_SIDE_USES_IMPORT', dep);
        \\export function unused() {
        \\  return 'DIRECT_REEXPORT_SIDE_UNUSED_EXPORT';
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_KEEP_LIVE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_SIDE_USES_IMPORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_DEP_EVAL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_DEP_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_SIDE_UNUSED_EXPORT") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DIRECT_REEXPORT_LIVE_DEP_DEAD") == null);
}

test "TreeShaking: class extends call expression preserved (#1261 edge)" {
    // class Foo extends getBase() — extends call은 side-effect이므로 보존.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\function getBase() { console.log("EXTENDS_CALL_MARKER"); return class {}; }
        \\export class Unused extends getBase() {}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXTENDS_CALL_MARKER") != null);
}

test "#1291 실제 증상: \"use strict\" + non-simple params 있는 모듈이 graph에서 스킵됨" {
    // 실제 이슈 재현: backend.js 같은 webpack UMD 번들이 내부 함수에
    // `"use strict"` + destructuring params 조합을 가질 때 parser가 validation 에러를
    // 내고 graph.zig가 모듈 전체를 스킵 → require 참조가 생기지만 정의는 없음.
    //
    // SyntaxError지만 V8/Hermes 런타임은 실행하므로 번들러는 경고로 처리해야 함
    // (esbuild/rollup 동일 정책).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\function foo({ a, b }) {
        \\    "use strict";
        \\    return a + b;
        \\}
        \\module.exports = foo;
    );
    try writeFile(tmp.dir, "entry.js",
        \\const foo = require('./lib.js');
        \\console.log(foo({ a: 1, b: 2 }));
    );
    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_lib = __commonJS") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports = foo") != null);
}

test "TreeShaking: dead statement references don't keep upstream module (#1551)" {
    // svelte/store readable 누수 재현:
    //   entry → barrel의 readable만 사용. barrel 내 unused_fn이 runtime를 참조.
    //   unused_fn은 statement-level DCE로 제거되지만 AST에 참조가 남아
    //   processModuleImports의 reference_count > 0 판정에 의해 runtime이
    //   가짜 used로 마킹되는 문제(#1551). #1558 Step 3+4에서 BFS fixpoint 통합 +
    //   live_mod_idx로 정정 (reachable statement 안의 import만 used로 마킹).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const UPSTREAM_MARKER = "RUNTIME_LEAKED";
        \\export const UPSTREAM_B = "B_LEAKED";
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { UPSTREAM_MARKER, UPSTREAM_B } from './runtime';
        \\export function readable(v: number) { return { value: v }; }
        \\export function unused_fn() {
        \\  return UPSTREAM_MARKER + UPSTREAM_B;
        \\}
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { readable } from './barrel';
        \\console.log(readable(42).value);
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readable") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RUNTIME_LEAKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_LEAKED") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unused_fn") == null);
}

test "TreeShaking: dead statement import chain 2 hops removed (#1551)" {
    // 2-hop 체인: entry → mid. mid는 live export + dead export.
    // dead 함수 안에서만 runtime 참조 — 체인 전체가 제거되어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const RUNTIME_TWO_HOP_MARKER = "LEAKED_TWO_HOP";
    );
    try writeFile(tmp.dir, "mid.ts",
        \\import { RUNTIME_TWO_HOP_MARKER } from './runtime';
        \\export function used_mid(n: number) { return n * 2; }
        \\export function dead_mid() { return RUNTIME_TWO_HOP_MARKER; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { used_mid } from './mid';
        \\console.log(used_mid(21));
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "used_mid") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LEAKED_TWO_HOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "dead_mid") == null);
}

test "TreeShaking: live statement preserves upstream module (#1551 anti-regression)" {
    // 반대 케이스: runtime import가 live 함수에서 참조되면 runtime 모듈은 보존.
    // 보호 모듈 집합(alias 타겟)이 정상 동작하는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "runtime.ts",
        \\export const RUNTIME_LIVE = "RUNTIME_STILL_NEEDED";
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\import { RUNTIME_LIVE } from './runtime';
        \\export function hello() { return RUNTIME_LIVE; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\import { hello } from './barrel';
        \\console.log(hello());
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "RUNTIME_STILL_NEEDED") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello") != null);
}

// kysely 회귀 #2052: TS interface-only 가 strip 후 빈 `export {}` 만 남고, post-transform
// AST 에서 transformer 가 그 marker 까지 drop 하면 refresh 가 exports_kind 를 `.none` 으로
// 강등 → markEsmCjsHybrid Pass 2 가 implicit CJS 로 승격 → resolveOrCjsFallback 이 첫 번째
// `export *` source 의 빈 CJS wrapper 를 모든 named import 의 source 로 stick 시킴 →
// 실제 정의가 있는 다음 `export *` 는 walk 안 되어 dummy-driver.js 가 tree-shake 된다.
test "TreeShaking: export * chain through TS-stripped empty source still resolves named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Bar } from './barrel';
        \\console.log(new Bar().tag());
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './empty';
        \\export * from './real';
    );
    try writeFile(tmp.dir, "empty.ts",
        \\export {};
    );
    try writeFile(tmp.dir, "real.ts",
        \\export class Bar {
        \\  tag() { return 'EXPORT_STAR_CHAIN_KEPT'; }
        \\}
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "EXPORT_STAR_CHAIN_KEPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Bar") != null);
}

// cheerio 회귀 #2051: namespace import (`import * as ns from 'cjslib'`) 의 모든 소비자가
// tree-shake 로 사라졌는데 ImportBinding 자체는 살아 있어 linker 가 `var ns =
// __toESM(require_X(), 1)` 를 emit. 그러나 해당 CJS wrapper 는 모듈 미포함이라 정의되지
// 않아 `require_X is not defined` ReferenceError. preamble emit 도 같이 drop 해야 한다.
test "TreeShaking: namespace import preamble dropped when target excluded from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './lib';
        \\console.log(used());
    );
    // lib.js 가 namespace 로 cjslib 을 import 하지만, 소비자 (`heavy`) 는 entry 에서 안 쓴다.
    try writeFile(tmp.dir, "lib.js",
        \\import * as cjslib from './cjslib.cjs';
        \\export function used() { return 'NS_TARGET_DROP_USED'; }
        \\export function heavy() { return cjslib.bar(); }
    );
    try writeFile(tmp.dir, "cjslib.cjs",
        \\'use strict';
        \\exports.bar = function() { return 'NS_TARGET_DROP_HEAVY'; };
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_USED") != null);
    // heavy() 는 사용 안 하므로 cjslib + 본문 모두 prune 되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_TARGET_DROP_HEAVY") == null);
    // `var X = __toESM(require_cjslib_cjs(), 1)` 같은 orphan preamble 이 남으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require_cjslib") == null);
}
