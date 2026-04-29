//! 플러그인 시스템 테스트
//!
//! - 단위 테스트: PluginRunner의 각 훅 실행 로직 검증
//! - 통합 테스트: Bundler.bundle()을 통한 end-to-end 검증

const std = @import("std");
const Bundler = @import("bundler.zig").Bundler;
const plugin_mod = @import("plugin.zig");
const Plugin = plugin_mod.Plugin;
const PluginRunner = plugin_mod.PluginRunner;
const ResolveResult = @import("resolver.zig").ResolveResult;
const OutputFile = @import("emitter.zig").OutputFile;
const CompiledOutputCache = @import("compiled_cache.zig").CompiledOutputCache;
const test_helpers = @import("test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// 단위 테스트: PluginRunner
// ============================================================

test "PluginRunner: empty plugins is no-op" {
    const runner = PluginRunner.init(&.{});
    try std.testing.expect(runner.isEmpty());

    const resolve_result = try runner.runResolveId("foo", null, std.testing.allocator);
    try std.testing.expect(resolve_result == null);

    const load_result = try runner.runLoad("foo.ts", std.testing.allocator);
    try std.testing.expect(load_result == null);

    const transform_result = try runner.runTransform("code", "id", std.testing.allocator);
    try std.testing.expect(transform_result == null);

    const render_result = try runner.runRenderChunk("code", "chunk", std.testing.allocator);
    try std.testing.expect(render_result == null);

    runner.runGenerateBundle(&.{});
}

// --- resolveId 훅 테스트 ---

fn testResolveIdHook(_: ?*anyopaque, specifier: []const u8, _: ?[]const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?plugin_mod.ResolvedModule {
    if (std.mem.eql(u8, specifier, "virtual:config")) {
        return .{ .file = .{
            .path = try allocator.dupe(u8, "/virtual/config.js"),
            .module_type = .javascript,
        } };
    }
    return null;
}

test "PluginRunner: resolveId first mode" {
    const plugins = [_]Plugin{
        .{ .name = "test-resolve", .resolveId = testResolveIdHook },
    };
    const runner = PluginRunner.init(&plugins);

    // 매칭되는 specifier → non-null
    const result = try runner.runResolveId("virtual:config", null, std.testing.allocator);
    try std.testing.expect(result != null);
    const path = switch (result.?) {
        .file => |f| f.path,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("/virtual/config.js", path);
    std.testing.allocator.free(path);

    // 매칭 안 되는 specifier → null (기본 resolver 사용)
    const result2 = try runner.runResolveId("./normal", null, std.testing.allocator);
    try std.testing.expect(result2 == null);
}

// --- load 훅 테스트 ---

fn testLoadHook(_: ?*anyopaque, path: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    if (std.mem.endsWith(u8, path, ".custom")) {
        return try allocator.dupe(u8, "export default 'custom-loaded';");
    }
    return null;
}

test "PluginRunner: load first mode" {
    const plugins = [_]Plugin{
        .{ .name = "test-load", .load = testLoadHook },
    };
    const runner = PluginRunner.init(&plugins);

    const result = try runner.runLoad("module.custom", std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("export default 'custom-loaded';", result.?);
    std.testing.allocator.free(result.?);

    // 매칭 안 되는 확장자 → null (파일 시스템에서 읽기)
    const result2 = try runner.runLoad("module.ts", std.testing.allocator);
    try std.testing.expect(result2 == null);
}

// --- transform 훅 테스트 (체이닝) ---

fn testTransformHookA(_: ?*anyopaque, code: []const u8, _: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    return std.mem.concat(allocator, u8, &.{ "/* A */", code }) catch return error.OutOfMemory;
}

fn testTransformHookB(_: ?*anyopaque, code: []const u8, _: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    return std.mem.concat(allocator, u8, &.{ "/* B */", code }) catch return error.OutOfMemory;
}

test "PluginRunner: transform chaining" {
    const plugins = [_]Plugin{
        .{ .name = "transform-a", .transform = testTransformHookA },
        .{ .name = "transform-b", .transform = testTransformHookB },
    };
    const runner = PluginRunner.init(&plugins);

    const result = try runner.runTransform("original", "test.js", std.testing.allocator);
    try std.testing.expect(result != null);
    // B가 A의 결과를 받으므로: "/* B *//* A */original"
    try std.testing.expectEqualStrings("/* B *//* A */original", result.?);
    std.testing.allocator.free(result.?);
}

// --- renderChunk 훅 테스트 ---

fn testRenderChunkHook(_: ?*anyopaque, code: []const u8, _: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    return std.mem.concat(allocator, u8, &.{ "/* rendered */\n", code }) catch return error.OutOfMemory;
}

test "PluginRunner: renderChunk chaining" {
    const plugins = [_]Plugin{
        .{ .name = "test-render", .renderChunk = testRenderChunkHook },
    };
    const runner = PluginRunner.init(&plugins);

    const result = try runner.runRenderChunk("chunk code", "main", std.testing.allocator);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.startsWith(u8, result.?, "/* rendered */\n"));
    std.testing.allocator.free(result.?);
}

// --- generateBundle 훅 테스트 ---

var generate_bundle_called: bool = false;

fn testGenerateBundleHook(_: ?*anyopaque, _: []const OutputFile) void {
    generate_bundle_called = true;
}

test "PluginRunner: generateBundle all executed" {
    generate_bundle_called = false;
    const plugins = [_]Plugin{
        .{ .name = "test-generate", .generateBundle = testGenerateBundleHook },
    };
    const runner = PluginRunner.init(&plugins);

    runner.runGenerateBundle(&.{.{ .path = "out.js", .contents = "code" }});
    try std.testing.expect(generate_bundle_called);
}

// ============================================================
// 통합 테스트: Bundler.bundle()을 통한 플러그인 훅 실행 검증
// ============================================================

// --- transform 훅 통합 테스트 ---

fn integrationTransformHook(_: ?*anyopaque, code: []const u8, _: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    // 파싱 전에 호출되므로 실행 가능한 문을 삽입 (주석은 파서가 제거)
    return std.mem.concat(allocator, u8, &.{ "var __PLUGIN_TRANSFORM__ = true;\n", code }) catch return error.OutOfMemory;
}

test "Plugin integration: transform hook modifies output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 42;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "test-transform", .transform = integrationTransformHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // transform 훅이 삽입한 변수 선언이 출력에 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__PLUGIN_TRANSFORM__") != null);
    try std.testing.expect(!result.hasErrors());
}

fn transformAddsImportHook(_: ?*anyopaque, code: []const u8, id: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    if (!std.mem.endsWith(u8, id, "index.ts")) return null;
    return std.mem.concat(allocator, u8, &.{ "import './side';\n", code }) catch return error.OutOfMemory;
}

test "Plugin integration: transform-added imports are scanned from final source (#2038)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('entry-2038');");
    try writeFile(tmp.dir, "side.ts", "console.log('plugin-added-side-effect-2038');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "add-import-transform", .transform = transformAddsImportHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-added-side-effect-2038") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "entry-2038") != null);
}

fn transformAddsPurePackageImportHook(_: ?*anyopaque, _: []const u8, id: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    if (!std.mem.endsWith(u8, id, "index.ts")) return null;
    return allocator.dupe(u8,
        \\import { used } from "pure-lib-2038";
        \\console.log(used);
        \\
    ) catch return error.OutOfMemory;
}

test "Plugin integration: transform-added package import feeds tree-shaking (#2038)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('original source replaced by plugin');");
    try writeFile(tmp.dir, "node_modules/pure-lib-2038/package.json",
        \\{"name":"pure-lib-2038","main":"index.js","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/pure-lib-2038/index.js",
        \\export const used = "plugin-pure-used-2038";
        \\export const unused = "plugin-pure-unused-2038";
        \\
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "add-pure-package-import-transform", .transform = transformAddsPurePackageImportHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
        .tree_shaking = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-pure-used-2038") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-pure-unused-2038") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "original source replaced") == null);
}

var compiled_cache_transform_marker: []const u8 = "A";

fn cacheSensitiveTransformHook(_: ?*anyopaque, _: []const u8, id: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    if (!std.mem.endsWith(u8, id, "index.ts")) return null;
    return std.fmt.allocPrint(
        allocator,
        "const marker = \"plugin-cache-{s}-2038\";\nconsole.log(marker);\n",
        .{compiled_cache_transform_marker},
    ) catch return error.OutOfMemory;
}

test "Plugin integration: transform output invalidates compiled cache (#2038)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('original source is stable');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var cache = CompiledOutputCache.init(std.testing.allocator);
    defer cache.deinit();

    const plugins = [_]Plugin{
        .{ .name = "cache-sensitive-transform", .transform = cacheSensitiveTransformHook },
    };

    compiled_cache_transform_marker = "A";
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .plugins = &plugins,
            .compiled_cache = &cache,
        });
        defer b.deinit();

        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-cache-A-2038") != null);
    }

    _ = cache.takeStats();
    compiled_cache_transform_marker = "B";
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .plugins = &plugins,
            .compiled_cache = &cache,
        });
        defer b.deinit();

        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-cache-B-2038") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-cache-A-2038") == null);
    }

    _ = cache.takeStats();
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .plugins = &plugins,
            .compiled_cache = &cache,
        });
        defer b.deinit();

        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);
        const stats = cache.takeStats();

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-cache-B-2038") != null);
        try std.testing.expect(stats.hits > 0);
    }
}

var compiled_cache_load_marker: []const u8 = "A";

fn cacheSensitiveLoadHook(_: ?*anyopaque, path: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    if (!std.mem.endsWith(u8, path, "index.ts")) return null;
    return std.fmt.allocPrint(
        allocator,
        "const marker = \"plugin-load-cache-{s}-2038\";\nconsole.log(marker);\n",
        .{compiled_cache_load_marker},
    ) catch return error.OutOfMemory;
}

test "Plugin integration: load output invalidates compiled cache (#2038)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('filesystem source is stable');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var cache = CompiledOutputCache.init(std.testing.allocator);
    defer cache.deinit();

    const plugins = [_]Plugin{
        .{ .name = "cache-sensitive-load", .load = cacheSensitiveLoadHook },
    };

    compiled_cache_load_marker = "A";
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .plugins = &plugins,
            .compiled_cache = &cache,
        });
        defer b.deinit();

        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-load-cache-A-2038") != null);
    }

    _ = cache.takeStats();
    compiled_cache_load_marker = "B";
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .plugins = &plugins,
            .compiled_cache = &cache,
        });
        defer b.deinit();

        const result = try b.bundle();
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-load-cache-B-2038") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "plugin-load-cache-A-2038") == null);
    }
}

// --- generateBundle 훅 통합 테스트 ---

var integration_generate_called: bool = false;
var integration_generate_output_len: usize = 0;

fn integrationGenerateBundleHook(_: ?*anyopaque, outputs: []const OutputFile) void {
    integration_generate_called = true;
    integration_generate_output_len = outputs.len;
}

test "Plugin integration: generateBundle hook is called" {
    integration_generate_called = false;
    integration_generate_output_len = 0;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "test-generate", .generateBundle = integrationGenerateBundleHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(integration_generate_called);
    try std.testing.expect(integration_generate_output_len > 0);
}

// --- plugins 없이 기존 동작 유지 테스트 ---

test "Plugin integration: no plugins preserves existing behavior" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 42;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 42;") != null);
    try std.testing.expect(!result.hasErrors());
}

// --- 다중 플러그인 체이닝 통합 테스트 ---

fn chainTransformA(_: ?*anyopaque, code: []const u8, _: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    return std.mem.concat(allocator, u8, &.{ "var CHAIN_A = true;\n", code }) catch return error.OutOfMemory;
}

fn chainTransformB(_: ?*anyopaque, code: []const u8, _: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    return std.mem.concat(allocator, u8, &.{ "var CHAIN_B = true;\n", code }) catch return error.OutOfMemory;
}

test "Plugin integration: multiple plugins chain transforms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "chain-a", .transform = chainTransformA },
        .{ .name = "chain-b", .transform = chainTransformB },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 두 플러그인 모두 적용되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CHAIN_A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CHAIN_B") != null);
    try std.testing.expect(!result.hasErrors());
}

// --- resolveId가 null 반환 시 기본 resolver fall through ---

fn nullResolveHook(_: ?*anyopaque, _: []const u8, _: ?[]const u8, _: std.mem.Allocator) plugin_mod.PluginError!?plugin_mod.ResolvedModule {
    return null;
}

test "Plugin integration: resolveId null falls through to default resolver" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import { y } from './dep';\nconsole.log(y);");
    try writeFile(tmp.dir, "dep.ts", "export const y = 99;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "null-resolve", .resolveId = nullResolveHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 기본 resolver가 dep.ts를 찾아서 번들해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const y = 99") != null);
    try std.testing.expect(!result.hasErrors());
}

// --- load 훅이 null 반환 시 파일 시스템 폴백 ---

fn nullLoadHook(_: ?*anyopaque, _: []const u8, _: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    return null;
}

test "Plugin integration: load null falls through to filesystem" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const z = 77; console.log(z);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "null-load", .load = nullLoadHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "const z = 77") != null);
    try std.testing.expect(!result.hasErrors());
}

// --- transform 훅이 유저 소스 파일(non-node_modules)에도 호출되는지 테스트 (#964) ---

var transform_all_call_count: usize = 0;
var transform_all_user_file_seen: bool = false;

fn countingTransformHook(_: ?*anyopaque, code: []const u8, id: []const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?[]const u8 {
    transform_all_call_count += 1;
    if (std.mem.indexOf(u8, id, "node_modules") == null) {
        transform_all_user_file_seen = true;
    }
    return allocator.dupe(u8, code) catch return error.OutOfMemory;
}

test "Plugin integration: transform hook is called for user source files (#964)" {
    transform_all_call_count = 0;
    transform_all_user_file_seen = false;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const hello = 'world';");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{ .name = "count-transform", .transform = countingTransformHook },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // transform 훅이 최소 1번 호출되어야 함
    try std.testing.expect(transform_all_call_count > 0);
    // 유저 소스 파일(non-node_modules)에 대해 호출되어야 함
    try std.testing.expect(transform_all_user_file_seen);
}

// ============================================================
// 단위 테스트: ResolvedModule union(enum) (#1885 Phase 1 PR 4a)
// ============================================================

const ResolvedModule = plugin_mod.ResolvedModule;
const ModuleType = @import("types.zig").ModuleType;

test "ResolvedModule: file variant 보존" {
    const m: ResolvedModule = .{ .file = .{
        .path = "/abs/foo.ts",
        .module_type = .javascript,
        .is_module_field = true,
    } };
    switch (m) {
        .file => |f| {
            try std.testing.expectEqualStrings("/abs/foo.ts", f.path);
            try std.testing.expectEqual(ModuleType.javascript, f.module_type);
            try std.testing.expect(f.is_module_field);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "ResolvedModule: virtual / dataurl / external / disabled / custom variant" {
    const v: ResolvedModule = .{ .virtual = .{ .path = "virtual:foo" } };
    switch (v) {
        .virtual => |x| try std.testing.expectEqualStrings("virtual:foo", x.path),
        else => return error.TestUnexpectedResult,
    }

    const d: ResolvedModule = .{ .dataurl = .{ .mime = "image/png", .data = "AAAA" } };
    switch (d) {
        .dataurl => |x| {
            try std.testing.expectEqualStrings("image/png", x.mime);
            try std.testing.expectEqualStrings("AAAA", x.data);
        },
        else => return error.TestUnexpectedResult,
    }

    const e: ResolvedModule = .{ .external = .{ .path = "react" } };
    switch (e) {
        .external => |x| try std.testing.expectEqualStrings("react", x.path),
        else => return error.TestUnexpectedResult,
    }

    const dis: ResolvedModule = .{ .disabled = .{ .path = "/abs/disabled.js", .module_type = .javascript } };
    switch (dis) {
        .disabled => |x| {
            try std.testing.expectEqualStrings("/abs/disabled.js", x.path);
            try std.testing.expectEqual(ModuleType.javascript, x.module_type);
        },
        else => return error.TestUnexpectedResult,
    }

    const c: ResolvedModule = .{ .custom = .{ .name = "my-plugin", .path = "/x" } };
    switch (c) {
        .custom => |x| {
            try std.testing.expectEqualStrings("my-plugin", x.name);
            try std.testing.expectEqualStrings("/x", x.path);
        },
        else => return error.TestUnexpectedResult,
    }
}

// Note: ResolvedModule = union(fs.Namespace) 자체가 컴파일 타임에 모든 Namespace
// variant 의 payload 정의 강제 — 별도 exhaustive 검증 테스트 불필요.

// ============================================================
// Lifecycle hooks: buildStart / buildEnd / closeBundle (#2156)
// ============================================================

const types = @import("types.zig");

const LifecycleLog = struct {
    var build_start_count: u32 = 0;
    var build_end_count: u32 = 0;
    var close_bundle_count: u32 = 0;
    var build_end_error_was_null: bool = true;
    var build_end_error_code: ?types.BundlerDiagnostic.ErrorCode = null;
    var build_start_should_fail: bool = false;

    fn reset() void {
        build_start_count = 0;
        build_end_count = 0;
        close_bundle_count = 0;
        build_end_error_was_null = true;
        build_end_error_code = null;
        build_start_should_fail = false;
    }
};

fn lifecycleBuildStart(_: ?*anyopaque) plugin_mod.PluginError!void {
    LifecycleLog.build_start_count += 1;
    if (LifecycleLog.build_start_should_fail) return error.PluginFailed;
}

fn lifecycleBuildEnd(_: ?*anyopaque, build_error: ?*const types.BundlerDiagnostic) plugin_mod.PluginError!void {
    LifecycleLog.build_end_count += 1;
    LifecycleLog.build_end_error_was_null = build_error == null;
    if (build_error) |d| LifecycleLog.build_end_error_code = d.code;
}

fn lifecycleCloseBundle(_: ?*anyopaque) plugin_mod.PluginError!void {
    LifecycleLog.close_bundle_count += 1;
}

test "PluginRunner: buildStart 모든 plugin 순차 실행" {
    LifecycleLog.reset();
    const plugins = [_]Plugin{
        .{ .name = "p1", .buildStart = lifecycleBuildStart },
        .{ .name = "p2", .buildStart = lifecycleBuildStart },
    };
    const runner = PluginRunner.init(&plugins);
    try runner.runBuildStart();
    try std.testing.expectEqual(@as(u32, 2), LifecycleLog.build_start_count);
}

test "PluginRunner: buildStart 한 plugin 실패 시 즉시 stop + 에러 전파" {
    LifecycleLog.reset();
    LifecycleLog.build_start_should_fail = true;
    const plugins = [_]Plugin{
        .{ .name = "fail", .buildStart = lifecycleBuildStart },
        .{ .name = "never", .buildStart = lifecycleBuildStart },
    };
    const runner = PluginRunner.init(&plugins);
    try std.testing.expectError(error.PluginFailed, runner.runBuildStart());
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_start_count); // 두 번째 plugin 미호출
}

test "PluginRunner: buildEnd error 인자 전달" {
    LifecycleLog.reset();
    const diag = types.BundlerDiagnostic{
        .code = .unresolved_import,
        .severity = .@"error",
        .message = "test error",
        .file_path = "test.ts",
        .span = .{ .start = 0, .end = 0 },
        .step = .resolve,
    };
    const plugins = [_]Plugin{
        .{ .name = "p1", .buildEnd = lifecycleBuildEnd },
    };
    const runner = PluginRunner.init(&plugins);
    runner.runBuildEnd(&diag);
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_end_count);
    try std.testing.expect(!LifecycleLog.build_end_error_was_null);
    try std.testing.expectEqual(types.BundlerDiagnostic.ErrorCode.unresolved_import, LifecycleLog.build_end_error_code.?);
}

fn lifecycleAlwaysFails(_: ?*anyopaque, _: ?*const types.BundlerDiagnostic) plugin_mod.PluginError!void {
    return error.PluginFailed;
}

fn lifecycleCloseBundleAlwaysFails(_: ?*anyopaque) plugin_mod.PluginError!void {
    return error.PluginFailed;
}

test "PluginRunner: buildEnd / closeBundle 의 plugin 에러는 swallow" {
    LifecycleLog.reset();
    const plugins = [_]Plugin{
        .{ .name = "fail", .buildEnd = lifecycleAlwaysFails, .closeBundle = lifecycleCloseBundleAlwaysFails },
        .{ .name = "p2", .buildEnd = lifecycleBuildEnd, .closeBundle = lifecycleCloseBundle },
    };
    const runner = PluginRunner.init(&plugins);
    runner.runBuildEnd(null);
    runner.runCloseBundle();
    // 첫 plugin 이 실패해도 두 번째 plugin 까지 호출됨
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_end_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.close_bundle_count);
}

test "Plugin integration: lifecycle hook 호출 순서 + 정상 build → buildEnd(null)" {
    LifecycleLog.reset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{
            .name = "lifecycle",
            .buildStart = lifecycleBuildStart,
            .buildEnd = lifecycleBuildEnd,
            .closeBundle = lifecycleCloseBundle,
        },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_start_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_end_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.close_bundle_count);
    try std.testing.expect(LifecycleLog.build_end_error_was_null);
}

test "Plugin integration: buildStart 실패 시 build 실패 + errdefer 경로로 buildEnd + closeBundle 호출" {
    LifecycleLog.reset();
    LifecycleLog.build_start_should_fail = true;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    const plugins = [_]Plugin{
        .{
            .name = "fail-start",
            .buildStart = lifecycleBuildStart,
            .buildEnd = lifecycleBuildEnd,
            .closeBundle = lifecycleCloseBundle,
        },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .plugins = &plugins,
    });
    defer b.deinit();

    try std.testing.expectError(error.PluginFailed, b.bundle());
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_start_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.build_end_count);
    try std.testing.expectEqual(@as(u32, 1), LifecycleLog.close_bundle_count);
    try std.testing.expect(LifecycleLog.build_end_error_was_null); // catastrophic path: build_error=null
}
