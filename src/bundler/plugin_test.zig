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

fn testResolveIdHook(_: ?*anyopaque, specifier: []const u8, _: ?[]const u8, allocator: std.mem.Allocator) plugin_mod.PluginError!?ResolveResult {
    if (std.mem.eql(u8, specifier, "virtual:config")) {
        return .{
            .path = try allocator.dupe(u8, "/virtual/config.js"),
            .module_type = .javascript,
        };
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
    try std.testing.expectEqualStrings("/virtual/config.js", result.?.path);
    std.testing.allocator.free(result.?.path);

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

fn nullResolveHook(_: ?*anyopaque, _: []const u8, _: ?[]const u8, _: std.mem.Allocator) plugin_mod.PluginError!?ResolveResult {
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
