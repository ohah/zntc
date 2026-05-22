//! Event-queue discovery scan workers for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const plugin_mod = @import("../plugin.zig");
const MpscChannel = @import("../mpsc_channel.zig").MpscChannel;
const profile = @import("../../profile.zig");
const Span = @import("../../lexer/token.zig").Span;
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const graph_glob = @import("glob.zig");
const expandGlobRecords = graph_glob.expandGlobRecords;
const graph_require_context = @import("require_context.zig");
const expandRequireContextRecords = graph_require_context.expandRecords;

/// resolve 결과를 저장하는 구조체. scanWorker가 기록, 메인 스레드가 적용.
pub const ResolveOutput = struct {
    resolved: ?plugin_mod.ResolvedModule = null,
    is_error: bool = false,
    skipped: bool = false,
};

/// 이벤트 큐 기반 스캔 결과. 워커가 채널로 전송, 메인이 수신.
pub const ScanResult = struct {
    module_idx: ModuleIndex,
    resolve_outputs: []ResolveOutput,
};

/// Event-queue scan worker: parse and resolve, then send the result to the channel.
/// It does not mutate graph topology, so the main thread remains the sole writer.
pub fn scanWorker(self: *ModuleGraph, idx: ModuleIndex, channel: *MpscChannel(ScanResult)) void {
    channel.send(self.scanModule(idx));
}

pub fn scanModuleRangeSequential(self: *ModuleGraph, start: usize, end: usize) !usize {
    var i = start;
    while (i < end) : (i += 1) {
        const m = self.modules.at(i);
        if (m.state == .ready) continue;
        const result = self.scanModule(.fromUsize(i));
        try self.applyScanResult(result);
    }
    return end;
}

pub fn applyScanResult(self: *ModuleGraph, result: ScanResult) !void {
    var apply_scope = profile.begin(.graph_discover_apply);
    defer apply_scope.end();
    defer if (result.resolve_outputs.len > 0) self.allocator.free(result.resolve_outputs);

    const mod_idx = @intFromEnum(result.module_idx);
    const mod_ptr = self.modules.at(mod_idx);
    self.applySideEffectsFromPackageJson(mod_ptr);
    mod_ptr.state = .ready;

    const records = mod_ptr.import_records;
    const resolves = result.resolve_outputs;

    // SegmentedList (#1779 PR #3) appends do not invalidate existing pointers,
    // so *Module pointers held by inflight workers remain valid. The old
    // ArrayList-era drain/realloc path is no longer needed.
    for (records, 0..) |record, rec_i| {
        if (rec_i < resolves.len) {
            if (resolves[rec_i].skipped and !resolves[rec_i].is_error) {
                self.markRecordLazyResolved(mod_idx, rec_i);
                if (resolves[rec_i].resolved) |resolved| self.discardResolvedModule(resolved);
                continue;
            }
            try self.applyResolveResult(mod_idx, rec_i, record, resolves[rec_i].resolved, resolves[rec_i].is_error);
        }
    }
    if (self.hasDeferredRequestedImports(mod_idx)) {
        try self.resolveModuleImports(result.module_idx);
    }
    // Register require.context matches as graph dependencies (#1579 Phase 4).
    try self.applyContextDepResults(mod_idx);
}

pub fn scanModule(self: *ModuleGraph, idx: ModuleIndex) ScanResult {
    var scope = profile.begin(.graph_discover_scan_worker);
    defer scope.end();

    {
        var parse_scope = profile.begin(.graph_discover_scan_worker_parse);
        defer parse_scope.end();
        self.parseModule(idx);
    }

    const mod_idx = @intFromEnum(idx);
    if (mod_idx >= self.modules.count()) {
        return .{ .module_idx = idx, .resolve_outputs = &.{} };
    }

    const mod_ptr = self.modules.at(mod_idx);
    self.applySideEffectsFromPackageJson(mod_ptr);
    if (mod_ptr.import_records.len == 0) {
        return .{ .module_idx = idx, .resolve_outputs = &.{} };
    }

    const module_path = mod_ptr.path;
    const source_dir = mod_ptr.sourceDir();

    const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

    // import.meta.glob: 워커에서 glob 확장 수행
    expandGlobRecords(self.allocator, mod_ptr.import_records, source_dir);
    // require.context: plugin 으로 matches 주입 + context_expansion_deps 로 수집 (#1579 Phase 4).
    // import_records 는 건드리지 않으므로 len 변화 없음.
    expandRequireContextRecords(self, mod_idx);

    const records = mod_ptr.import_records;
    var results = self.allocator.alloc(ResolveOutput, records.len) catch {
        self.addDiag(.resolve_error, .@"error", module_path, Span.EMPTY, .resolve, "Out of memory allocating resolve results", null);
        return .{ .module_idx = idx, .resolve_outputs = &.{} };
    };
    for (results) |*r| r.* = .{};

    {
        var resolve_scope = profile.begin(.graph_discover_scan_worker_resolve);
        defer resolve_scope.end();

        for (records, 0..) |record, rec_i| {
            if (record.kind == .glob or record.kind == .require_context) {
                results[rec_i].skipped = true;
                continue;
            }
            if (record.resolved != .none or record.is_external) {
                results[rec_i].skipped = true;
                continue;
            }
            const should_link = self.shouldLinkResolvedRecordForModule(mod_idx, rec_i, record);

            if (plugin_runner) |runner| {
                if (self.shouldRunResolveId(record.specifier)) {
                    // this.resolve (PR4): resolveId hook 에 ResolveCache 전달.
                    var hook_ctx: plugin_mod.HookContext = .{ .resolve_cache = @ptrCast(self.resolve_cache) };
                    const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator, &hook_ctx) catch |err| switch (err) {
                        error.PluginFailed => {
                            self.addPluginFailureDiag(hook_ctx.failure, module_path, record.span, .resolve);
                            results[rec_i] = .{ .is_error = true, .skipped = !should_link };
                            continue;
                        },
                        error.OutOfMemory => {
                            self.addDiag(.resolve_error, .@"error", module_path, record.span, .resolve, "Out of memory during resolve", record.specifier);
                            continue;
                        },
                    };
                    if (resolve_result) |plugin_result| {
                        results[rec_i] = .{ .resolved = plugin_result, .is_error = false, .skipped = !should_link };
                        continue;
                    }
                }
            }

            const resolved = self.resolve_cache.resolveThreadSafe(
                source_dir,
                record.specifier,
                record.kind,
            ) catch |err| switch (err) {
                error.ModuleNotFound => {
                    results[rec_i] = .{ .is_error = true, .skipped = !should_link };
                    continue;
                },
                error.OutOfMemory => {
                    self.addDiag(.resolve_error, .@"error", module_path, record.span, .resolve, "Out of memory during resolve", record.specifier);
                    continue;
                },
            };
            results[rec_i] = .{ .resolved = resolved, .skipped = !should_link };
        }
    }

    return .{ .module_idx = idx, .resolve_outputs = results };
}
