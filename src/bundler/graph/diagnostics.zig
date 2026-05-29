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
