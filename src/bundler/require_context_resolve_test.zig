//! require.context Phase 2 — host plugin (resolveContext) hook + graph diagnostic 테스트.
//! Reference: glob 의 expandGlobRecords + codegen inline expansion 모델.
//! Phase 2 산출물:
//!   1. Plugin.resolveContext hook 정의 + PluginRunner.runResolveContext
//!   2. expandRequireContextRecords (plugin hook 호출 + record.context_matches 채움)
//!   3. record.context_invalid_reason → BundlerDiagnostic.require_context_invalid
//!   4. plugin 미구현 → BundlerDiagnostic.require_context_no_handler (warning)
//!   5. graph resolve loop 에서 require_context kind skip (glob 와 동일)
//!
//! 매칭 후 dep 등록 / 가상 모듈 emit 은 Phase 3.

const std = @import("std");
const types = @import("types.zig");
const ImportRecord = types.ImportRecord;
const ImportKind = types.ImportKind;
const plugin_mod = @import("plugin.zig");
const Plugin = plugin_mod.Plugin;
const PluginRunner = plugin_mod.PluginRunner;
const PluginError = plugin_mod.PluginError;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const Span = @import("../lexer/token.zig").Span;
const writeFile = @import("test_helpers.zig").writeFile;
const resolve_cache_mod = @import("resolve_cache.zig");

// ============================================================
// A. PluginRunner.runResolveContext — pure unit
// ============================================================

const RecordedCall = struct {
    var dir_buf: [256]u8 = undefined;
    var dir_len: usize = 0;
    var recursive: bool = false;
    var filter: ?[]const u8 = null;
    var flags: ?[]const u8 = null;
    var importer_buf: [256]u8 = undefined;
    var importer_len: usize = 0;
    var call_count: u32 = 0;

    fn reset() void {
        dir_len = 0;
        recursive = false;
        filter = null;
        flags = null;
        importer_len = 0;
        call_count = 0;
    }

    fn dir() []const u8 {
        return dir_buf[0..dir_len];
    }
    fn importer() []const u8 {
        return importer_buf[0..importer_len];
    }
};

fn captureCallback(
    _: ?*anyopaque,
    dir: []const u8,
    recursive: bool,
    filter_pattern: ?[]const u8,
    filter_flags: ?[]const u8,
    importer: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    RecordedCall.call_count += 1;
    RecordedCall.dir_len = @min(dir.len, RecordedCall.dir_buf.len);
    @memcpy(RecordedCall.dir_buf[0..RecordedCall.dir_len], dir[0..RecordedCall.dir_len]);
    RecordedCall.recursive = recursive;
    RecordedCall.filter = filter_pattern;
    RecordedCall.flags = filter_flags;
    RecordedCall.importer_len = @min(importer.len, RecordedCall.importer_buf.len);
    @memcpy(RecordedCall.importer_buf[0..RecordedCall.importer_len], importer[0..RecordedCall.importer_len]);

    return try allocator.alloc([]const u8, 0); // 매칭 0개 (capture 만 검증)
}

fn matchingCallback(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    // contract: outer slice + inner string 모두 allocator 소유 (graph 가 free)
    const result = try allocator.alloc([]const u8, 3);
    result[0] = try allocator.dupe(u8, "./a.tsx");
    result[1] = try allocator.dupe(u8, "./b.tsx");
    result[2] = try allocator.dupe(u8, "./c.tsx");
    return result;
}

fn nullCallback(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    _: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    return null;
}

fn errorCallback(
    _: ?*anyopaque,
    _: []const u8,
    _: bool,
    _: ?[]const u8,
    _: ?[]const u8,
    _: []const u8,
    _: std.mem.Allocator,
) PluginError!?[]const []const u8 {
    return error.PluginFailed;
}

/// Plugin contract 에 따라 outer + inner 모두 free.
fn freeMatches(alloc: std.mem.Allocator, matches: []const []const u8) void {
    for (matches) |s| alloc.free(s);
    alloc.free(matches);
}

test "runResolveContext: empty plugins → null" {
    const runner = PluginRunner.init(&.{});
    const result = try runner.runResolveContext("./pages", true, null, null, "/tmp/foo.ts", std.testing.allocator);
    try std.testing.expect(result == null);
}

test "runResolveContext: plugin without hook → null" {
    const plugins = [_]Plugin{.{ .name = "noop" }};
    const runner = PluginRunner.init(&plugins);
    const result = try runner.runResolveContext("./pages", true, null, null, "/tmp/foo.ts", std.testing.allocator);
    try std.testing.expect(result == null);
}

test "runResolveContext: hook called with all args propagated" {
    RecordedCall.reset();
    const plugins = [_]Plugin{.{ .name = "capture", .resolveContext = captureCallback }};
    const runner = PluginRunner.init(&plugins);
    const result = try runner.runResolveContext("./app", true, "\\.tsx?$", "i", "/proj/index.ts", std.testing.allocator);
    try std.testing.expect(result != null);
    defer freeMatches(std.testing.allocator, result.?);

    try std.testing.expectEqual(@as(u32, 1), RecordedCall.call_count);
    try std.testing.expectEqualStrings("./app", RecordedCall.dir());
    try std.testing.expectEqual(true, RecordedCall.recursive);
    try std.testing.expectEqualStrings("\\.tsx?$", RecordedCall.filter.?);
    try std.testing.expectEqualStrings("i", RecordedCall.flags.?);
    try std.testing.expectEqualStrings("/proj/index.ts", RecordedCall.importer());
}

test "runResolveContext: first non-null wins (multiple plugins)" {
    const plugins = [_]Plugin{
        .{ .name = "null", .resolveContext = nullCallback },
        .{ .name = "match", .resolveContext = matchingCallback },
        .{ .name = "should-not-call", .resolveContext = matchingCallback },
    };
    const runner = PluginRunner.init(&plugins);
    const result = try runner.runResolveContext("./pages", true, null, null, "/proj/index.ts", std.testing.allocator);
    try std.testing.expect(result != null);
    defer freeMatches(std.testing.allocator, result.?);
    try std.testing.expectEqual(@as(usize, 3), result.?.len);
}

test "runResolveContext: all plugins null → null" {
    const plugins = [_]Plugin{
        .{ .name = "null1", .resolveContext = nullCallback },
        .{ .name = "null2", .resolveContext = nullCallback },
    };
    const runner = PluginRunner.init(&plugins);
    const result = try runner.runResolveContext("./pages", true, null, null, "/proj/index.ts", std.testing.allocator);
    try std.testing.expect(result == null);
}

test "runResolveContext: plugin returns empty slice (matched 0 files) — valid" {
    RecordedCall.reset();
    const plugins = [_]Plugin{.{ .name = "empty", .resolveContext = captureCallback }};
    const runner = PluginRunner.init(&plugins);
    const result = try runner.runResolveContext("./empty-dir", true, null, null, "/proj/index.ts", std.testing.allocator);
    try std.testing.expect(result != null);
    defer freeMatches(std.testing.allocator, result.?);
    try std.testing.expectEqual(@as(usize, 0), result.?.len);
}

test "runResolveContext: plugin error propagated" {
    const plugins = [_]Plugin{.{ .name = "err", .resolveContext = errorCallback }};
    const runner = PluginRunner.init(&plugins);
    try std.testing.expectError(
        error.PluginFailed,
        runner.runResolveContext("./pages", true, null, null, "/proj/index.ts", std.testing.allocator),
    );
}

// ============================================================
// B. ImportRecord.context_matches 필드 + 기본값
// ============================================================

test "ImportRecord: context_matches default is null" {
    const r = ImportRecord{
        .specifier = "./pages",
        .kind = .require_context,
        .span = Span.EMPTY,
    };
    try std.testing.expect(r.context_matches == null);
}

test "ImportRecord: context_matches can be assigned slice" {
    const matches = [_][]const u8{ "./a.tsx", "./b.tsx" };
    const r = ImportRecord{
        .specifier = "./pages",
        .kind = .require_context,
        .span = Span.EMPTY,
        .context_matches = &matches,
    };
    try std.testing.expect(r.context_matches != null);
    try std.testing.expectEqual(@as(usize, 2), r.context_matches.?.len);
}

test "ImportRecord: context_matches empty slice is valid (matched 0)" {
    const matches: []const []const u8 = &.{};
    const r = ImportRecord{
        .specifier = "./empty",
        .kind = .require_context,
        .span = Span.EMPTY,
        .context_matches = matches,
    };
    try std.testing.expect(r.context_matches != null);
    try std.testing.expectEqual(@as(usize, 0), r.context_matches.?.len);
}

// ============================================================
// C. BundlerDiagnostic.ErrorCode 확장
// ============================================================

test "BundlerDiagnostic.ErrorCode: require_context_invalid exists" {
    const code: types.BundlerDiagnostic.ErrorCode = .require_context_invalid;
    _ = code;
}

test "BundlerDiagnostic.ErrorCode: require_context_no_handler exists" {
    const code: types.BundlerDiagnostic.ErrorCode = .require_context_no_handler;
    _ = code;
}

// ============================================================
// D. Graph integration — require.context 가 dep 로 안 들어감 + diagnostic
// ============================================================

fn dirPath(tmp: *std.testing.TmpDir) ![]const u8 {
    return try tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

test "graph: require.context invalid_reason → require_context_invalid diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // require.context(42) — invalid (numeric directory)
    try writeFile(tmp.dir, "index.ts", "const ctx = require.context(42);");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    var has_invalid_diag = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .require_context_invalid) {
            has_invalid_diag = true;
            break;
        }
    }
    try std.testing.expect(has_invalid_diag);
}

test "graph: require.context valid + no plugin → require_context_no_handler diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "index.ts", "const ctx = require.context('./pages', true, /\\.tsx?$/, 'sync');");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    var has_no_handler_diag = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .require_context_no_handler) {
            has_no_handler_diag = true;
            break;
        }
    }
    try std.testing.expect(has_no_handler_diag);
}

test "graph: require.context with plugin → context_matches populated, no diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "index.ts", "const ctx = require.context('./pages', true, /\\.tsx?$/, 'sync');");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    const plugins = [_]Plugin{.{ .name = "match", .resolveContext = matchingCallback }};
    graph.plugins = &plugins;

    try graph.build(&.{entry});

    // record.context_matches 채워졌는지 확인. 메모리는 module.deinit 가 자동 free.
    var found_matches = false;
    for (graph.modules.items) |m| {
        for (m.import_records) |r| {
            if (r.kind == .require_context and r.context_matches != null and r.context_matches.?.len == 3) {
                found_matches = true;
            }
        }
    }
    try std.testing.expect(found_matches);

    // require_context 관련 diagnostic 없어야
    for (graph.diagnostics.items) |d| {
        try std.testing.expect(d.code != .require_context_invalid);
        try std.testing.expect(d.code != .require_context_no_handler);
    }
}

test "graph: require.context kind skipped in resolve loop (no module_not_found)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // require.context 의 specifier ('./nonexistent-dir') 가 일반 require 였으면 unresolved.
    // require_context 는 skip 되어야 하므로 unresolved_import diagnostic 안 나와야.
    try writeFile(tmp.dir, "index.ts", "const ctx = require.context('./nonexistent-dir');");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // require.context 가 일반 resolve 경로 안 탐 → unresolved_import 없음.
    // (require_context_no_handler 는 plugin 없어서 나올 수 있음 — 그건 OK)
    for (graph.diagnostics.items) |d| {
        try std.testing.expect(d.code != .unresolved_import);
    }
}
