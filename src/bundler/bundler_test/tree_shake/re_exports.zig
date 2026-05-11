const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Tree-shaking export-star and direct re-export tests
// ============================================================

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

test "TreeShaking: unused pure computed object key initializer is pruned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from './computed-key';
        \\console.log(used);
    );
    try writeFile(tmp.dir, "computed-key.ts",
        \\function makeId() {
        \\  return 'COMPUTED_KEY_INIT_SHOULD_DROP';
        \\}
        \\function makeFactory() {
        \\  return makeId();
        \\}
        \\var keySymbol = /* @__PURE__ */ Symbol.for("computed-key-test");
        \\var unusedHolder = { [keySymbol]: makeFactory };
        \\export const used = 'COMPUTED_KEY_USED_MARKER';
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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPUTED_KEY_USED_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "COMPUTED_KEY_INIT_SHOULD_DROP") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "makeFactory") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "unusedHolder") == null);
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
