//! Diagnostic helpers for ModuleGraph.

const BundlerDiagnostic = @import("../types.zig").BundlerDiagnostic;
const Span = @import("../../lexer/token.zig").Span;
const plugin_mod = @import("../plugin.zig");
const source_map_trace = @import("../../codegen/source_map_trace.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

pub fn addDiag(
    self: *ModuleGraph,
    code: BundlerDiagnostic.ErrorCode,
    severity: BundlerDiagnostic.Severity,
    file_path: []const u8,
    span: Span,
    step: BundlerDiagnostic.Step,
    message: []const u8,
    suggestion: ?[]const u8,
) void {
    self.diag_mutex.lock();
    defer self.diag_mutex.unlock();
    // A failed transform refresh can leave a ready module with a transformed
    // AST and transform_cache. Latch graph errors until the modules are
    // destroyed by prepareForPreservedRebuild.
    if (severity == .@"error") self.preserved_graph_invalidated = true;
    self.diagnostics.append(self.allocator, .{
        .code = code,
        .severity = severity,
        .message = message,
        .file_path = file_path,
        .span = span,
        .step = step,
        .suggestion = suggestion,
    }) catch {};
}

/// `message`·`file_path` 를 복사해 그래프가 소유하게 한 뒤 진단을 추가한다 — 원본이 곧
/// 해제되는 메모리(예: worker 서브빌드 arena)에 있을 때 쓴다.
pub fn addOwnedDiag(
    self: *ModuleGraph,
    code: BundlerDiagnostic.ErrorCode,
    severity: BundlerDiagnostic.Severity,
    file_path_src: []const u8,
    span: Span,
    step: BundlerDiagnostic.Step,
    message_src: []const u8,
    suggestion: ?[]const u8,
) !void {
    const message = try self.allocator.dupe(u8, message_src);
    errdefer self.allocator.free(message);
    const file_path = try self.allocator.dupe(u8, file_path_src);
    errdefer self.allocator.free(file_path);
    {
        self.diag_mutex.lock();
        defer self.diag_mutex.unlock();
        try self.owned_diagnostic_strings.ensureUnusedCapacity(self.allocator, 2);
        self.owned_diagnostic_strings.appendAssumeCapacity(message);
        self.owned_diagnostic_strings.appendAssumeCapacity(file_path);
    }
    addDiag(self, code, severity, file_path, span, step, message, suggestion);
}

/// Atomically publish a diagnostic whose source graph is about to die.
/// All fallible work precedes content/latch publication under the same lock.
pub fn addOwnedDiagnostic(self: *ModuleGraph, source: BundlerDiagnostic) !void {
    const message = try self.allocator.dupe(u8, source.message);
    errdefer self.allocator.free(message);
    const file_path = try self.allocator.dupe(u8, source.file_path);
    errdefer self.allocator.free(file_path);
    const suggestion = if (source.suggestion) |text| try self.allocator.dupe(u8, text) else null;
    errdefer if (suggestion) |text| self.allocator.free(text);
    self.diag_mutex.lock();
    defer self.diag_mutex.unlock();
    try self.owned_diagnostic_strings.ensureUnusedCapacity(self.allocator, if (suggestion != null) 3 else 2);
    try self.diagnostics.ensureUnusedCapacity(self.allocator, 1);
    var owned = source;
    owned.message = message;
    owned.file_path = file_path;
    owned.suggestion = suggestion;
    self.owned_diagnostic_strings.appendAssumeCapacity(message);
    self.owned_diagnostic_strings.appendAssumeCapacity(file_path);
    if (suggestion) |text| self.owned_diagnostic_strings.appendAssumeCapacity(text);
    self.diagnostics.appendAssumeCapacity(owned);
    if (source.severity == .@"error") self.preserved_graph_invalidated = true;
}

pub fn addPluginFailureDiag(
    self: *ModuleGraph,
    failure: ?plugin_mod.PluginFailure,
    fallback_file: []const u8,
    span: Span,
    step: BundlerDiagnostic.Step,
) void {
    if (failure) |f| {
        defer f.deinit();
        tryAddPluginFailureDiag(self, f, fallback_file, span, step) catch {
            addDiag(self, .plugin_error, .@"error", fallback_file, span, step, "Plugin hook failed", null);
        };
    } else {
        addDiag(self, .plugin_error, .@"error", fallback_file, span, step, "Plugin hook failed", null);
    }
}

pub fn validatePluginSourceMaps(
    self: *ModuleGraph,
    source_maps: []const []const u8,
    fallback_file: []const u8,
    span: Span,
    step: BundlerDiagnostic.Step,
    hook_name: []const u8,
) bool {
    for (source_maps) |source_map_json| {
        var parsed = source_map_trace.parse(self.allocator, source_map_json) catch {
            const failure = plugin_mod.PluginFailure.init(
                self.allocator,
                "zntc:source-map",
                hook_name,
                "Invalid sourcemap returned by plugin",
                fallback_file,
                0,
                0,
            ) catch null;
            addPluginFailureDiag(self, failure, fallback_file, span, step);
            return false;
        };
        parsed.deinit();
    }
    return true;
}

fn tryAddPluginFailureDiag(
    self: *ModuleGraph,
    f: plugin_mod.PluginFailure,
    fallback_file: []const u8,
    span: Span,
    step: BundlerDiagnostic.Step,
) !void {
    const message = try f.formatMessage(self.allocator);
    errdefer self.allocator.free(message);

    const file_src = if (f.file_path.len > 0) f.file_path else fallback_file;
    const file_path = try self.allocator.dupe(u8, file_src);
    errdefer self.allocator.free(file_path);

    // (#3977) owned_diagnostic_strings 는 ModuleGraph 공유 ArrayList. discovery 가
    // 멀티스레드(기본 std.Thread.Pool)로 돌 때 여러 worker 가 plugin hook 실패로
    // (scanWorker→parseModule→runLoad/Transform, discovery_scan→resolveId 등) 동시에
    // 이 경로에 진입하면 무락 ensureUnusedCapacity/appendAssumeCapacity 가 realloc
    // race → use-after-free/double-free/힙 손상. 같은 파일 addDiag 가 self.diagnostics
    // 를 diag_mutex 로 보호하듯 이 공유 리스트도 동일 mutex 로 보호한다. addDiag(아래)
    // 가 같은 mutex 를 다시 잡으므로(비재귀) 별도 블록으로 분리해 재진입 데드락을 피한다.
    {
        self.diag_mutex.lock();
        defer self.diag_mutex.unlock();
        try self.owned_diagnostic_strings.ensureUnusedCapacity(self.allocator, 2);
        self.owned_diagnostic_strings.appendAssumeCapacity(message);
        self.owned_diagnostic_strings.appendAssumeCapacity(file_path);
    }

    addDiag(self, .plugin_error, .@"error", file_path, span, step, message, null);
}

fn checkAtomicWorkerDiagnostic(allocator: @import("std").mem.Allocator) !void {
    const std = @import("std");
    var cache = @import("../resolve_cache.zig").ResolveCache.init(allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(allocator, &cache);
    defer graph.deinit();
    var message = [_]u8{ 'b', 'a', 'd' };
    var path = [_]u8{ 'w', '.', 'j', 's' };
    var suggestion = [_]u8{ 'f', 'i', 'x' };
    const source: BundlerDiagnostic = .{
        .code = .parse_error,
        .severity = .@"error",
        .message = &message,
        .file_path = &path,
        .span = .{ .start = 3, .end = 4 },
        .step = .parse,
        .suggestion = &suggestion,
        .captured_location = .{ .span = .{ .start = 3, .end = 4 }, .source_length = 9, .line = 2, .column = 1 },
    };
    graph.addOwnedDiagnostic(source) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.len);
        try std.testing.expectEqual(@as(usize, 0), graph.owned_diagnostic_strings.items.len);
        try std.testing.expect(!graph.preserved_graph_invalidated);
        return err;
    };
    try std.testing.expect(graph.preserved_graph_invalidated);
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.len);
    const owned = graph.diagnostics.items[0];
    try std.testing.expect(owned.message.ptr != message[0..].ptr);
    try std.testing.expect(owned.file_path.ptr != path[0..].ptr);
    try std.testing.expect(owned.suggestion.?.ptr != suggestion[0..].ptr);
    @memset(&message, 'x');
    @memset(&path, 'x');
    @memset(&suggestion, 'x');
    try std.testing.expectEqualStrings("bad", owned.message);
    try std.testing.expectEqualStrings("w.js", owned.file_path);
    try std.testing.expectEqualStrings("fix", owned.suggestion.?);
    try std.testing.expectEqualDeep(source.captured_location, owned.captured_location);
}

test "worker parser diagnostic ownership is atomic under allocation failure" {
    const std = @import("std");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAtomicWorkerDiagnostic, .{});
}
