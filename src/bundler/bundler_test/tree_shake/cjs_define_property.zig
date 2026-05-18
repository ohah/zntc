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

test "TreeShaking CJS: __export getter keeps returned local binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js", "import { useIsRestoring } from './lib.js'; console.log(useIsRestoring());");
    try writeFile(tmp.dir, "lib.js",
        \\var __defProp = Object.defineProperty;
        \\var __export = (target, all) => {
        \\  for (var name in all) __defProp(target, name, { get: all[name], enumerable: true });
        \\};
        \\var __toCommonJS = (mod) => mod;
        \\var lib_exports = {};
        \\__export(lib_exports, {
        \\  useIsRestoring: () => useIsRestoring,
        \\  unusedExport: () => unusedExport
        \\});
        \\module.exports = __toCommonJS(lib_exports);
        \\var useIsRestoring = () => "USED_CJS_EXPORT_HELPER_MARKER";
        \\var unusedExport = () => "UNUSED_CJS_EXPORT_HELPER_MARKER";
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_CJS_EXPORT_HELPER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_CJS_EXPORT_HELPER_MARKER") == null);
}

test "TreeShaking CJS: whole require preserves member export assignments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");
    try writeFile(tmp.dir, "entry.js",
        \\const ReactFabric = require("./shim.js").default;
        \\console.log(ReactFabric.render());
    );
    try writeFile(tmp.dir, "shim.js",
        \\const ReactFabric = __DEV__ ? require("./renderer-dev.js") : require("./renderer-prod.js");
        \\globalThis.RN$stopSurface = ReactFabric.stopSurface;
        \\globalThis.registerCallableModule("ReactFabric", ReactFabric);
        \\exports.default = ReactFabric;
    );
    try writeFile(tmp.dir, "renderer-dev.js",
        \\exports.render = function render() { return "UNUSED_WHOLE_REQUIRE_DEV_RENDER_MARKER"; };
    );
    try writeFile(tmp.dir, "renderer-prod.js",
        \\exports.render = function render() { return "USED_WHOLE_REQUIRE_RENDER_MARKER"; };
        \\exports.stopSurface = function stopSurface() { return "USED_WHOLE_REQUIRE_STOP_MARKER"; };
        \\exports.unmountComponentAtNode = function unmountComponentAtNode() {
        \\  return "USED_WHOLE_REQUIRE_UNMOUNT_MARKER";
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .define = &.{.{ .key = "__DEV__", .value = "false" }},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_WHOLE_REQUIRE_RENDER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_WHOLE_REQUIRE_STOP_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_WHOLE_REQUIRE_UNMOUNT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_WHOLE_REQUIRE_DEV_RENDER_MARKER") == null);
}

test "TreeShaking CJS: namespace sentinel preserves member export assignments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");
    try writeFile(tmp.dir, "entry.js",
        \\import("./renderer.js").then((renderer) => {
        \\  globalThis.registerCallableModule("ReactFabric", renderer);
        \\});
    );
    try writeFile(tmp.dir, "renderer.js",
        \\exports.render = function render() { return "USED_CJS_SENTINEL_RENDER_MARKER"; };
        \\exports.stopSurface = function stopSurface() { return "USED_CJS_SENTINEL_STOP_MARKER"; };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_CJS_SENTINEL_RENDER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_CJS_SENTINEL_STOP_MARKER") != null);
}

test "TreeShaking CJS: default import preserves bare module.exports assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");
    try writeFile(tmp.dir, "entry.js",
        \\import Color from './color.js';
        \\class Card {
        \\  render(backgroundColor) {
        \\    return typeof backgroundColor === "string" ? Color(backgroundColor).alpha() : false;
        \\  }
        \\}
        \\console.log(new Card().render("#fff"));
    );
    try writeFile(tmp.dir, "color.js",
        \\const normalize = require("./normalize.js");
        \\function Color(value) {
        \\  if (!(this instanceof Color)) return new Color(value);
        \\  this.value = normalize(value);
        \\}
        \\Color.prototype.alpha = function alpha() {
        \\  return "USED_BARE_MODULE_EXPORTS_ALPHA_MARKER";
        \\};
        \\module.exports = Color;
    );
    try writeFile(tmp.dir, "normalize.js",
        \\module.exports = function normalize(value) {
        \\  return value;
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_BARE_MODULE_EXPORTS_ALPHA_MARKER") != null);
    var module_exports_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOf(u8, result.output[search_from..], "module.exports=")) |offset| {
        module_exports_count += 1;
        search_from += offset + "module.exports=".len;
    }
    try std.testing.expect(module_exports_count >= 2);
}

test "TreeShaking CJS: re-exported require member keeps CJS export assignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");
    try writeFile(tmp.dir, "entry.js",
        \\import { setupURLPolyfill } from './auto.js';
        \\setupURLPolyfill();
        \\console.log(new globalThis.URLSearchParams().tag);
    );
    try writeFile(tmp.dir, "auto.js",
        \\export { setupURLPolyfill } from './index.js';
    );
    try writeFile(tmp.dir, "index.js",
        \\export * from './url.js';
        \\export * from './url-search-params.js';
        \\function polyfillGlobal(name, getValue) {
        \\  globalThis[name] = getValue();
        \\}
        \\export function setupURLPolyfill() {
        \\  polyfillGlobal("URL", () => require("./url.js").URL);
        \\  polyfillGlobal("URLSearchParams", () => require("./url-search-params.js").URLSearchParams);
        \\}
    );
    try writeFile(tmp.dir, "url.js",
        \\import { URL } from './whatwg.js';
        \\URL.createObjectURL = function createObjectURL() {};
        \\export { URL };
    );
    try writeFile(tmp.dir, "url-search-params.js",
        \\export { URLSearchParams } from './whatwg.js';
    );
    try writeFile(tmp.dir, "whatwg.js",
        \\const { URL, URLSearchParams } = require("./wrapper.js");
        \\const sharedGlobalObject = {};
        \\URL.install(sharedGlobalObject);
        \\URLSearchParams.install(sharedGlobalObject);
        \\exports.URL = sharedGlobalObject.URL;
        \\exports.URLSearchParams = sharedGlobalObject.URLSearchParams;
    );
    try writeFile(tmp.dir, "wrapper.js",
        \\exports.URL = {
        \\  install(object) {
        \\    object.URL = function URL() {
        \\      this.tag = "UNUSED_URL_MARKER";
        \\    };
        \\  },
        \\};
        \\exports.URLSearchParams = {
        \\  install(object) {
        \\    object.URLSearchParams = function URLSearchParams() {
        \\      this.tag = "USED_URL_SEARCH_PARAMS_MARKER";
        \\    };
        \\  },
        \\};
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = false,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_URL_SEARCH_PARAMS_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.URLSearchParams=sharedGlobalObject.URLSearchParams") != null);
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

test "TreeShaking CJS: minified default import keeps __esModule marker for object default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json", "{\"sideEffects\": false}");
    try writeFile(tmp.dir, "entry.js",
        \\import BootSplash from './bootsplash.js';
        \\globalThis.__bootSplashHide = BootSplash.hide;
    );
    try writeFile(tmp.dir, "bootsplash.js",
        \\Object.defineProperty(exports, "__esModule", { value: true });
        \\exports.default = void 0;
        \\exports.hide = hide;
        \\exports.isVisible = isVisible;
        \\function hide() { return "USED_BOOT_SPLASH_HIDE_MARKER"; }
        \\function isVisible() { return true; }
        \\var BootSplash = exports.default = { hide, isVisible };
    );

    const entry = try absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .format = .iife,
        .strict_execution_order = true,
        .minify_syntax = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_BOOT_SPLASH_HIDE_MARKER") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "Object.defineProperty(exports,\"__esModule\"") != null or
            std.mem.indexOf(u8, result.output, "$dp(exports,\"__esModule\"") != null,
    );
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
