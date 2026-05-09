//! Import resolution and resolved dependency application for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const CachedResolvedDep = @import("../module.zig").CachedResolvedDep;
const plugin_mod = @import("../plugin.zig");
const resolve_cache_mod = @import("../resolve_cache.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const graph_glob = @import("glob.zig");
const expandGlobRecords = graph_glob.expandGlobRecords;
const graph_require_context = @import("require_context.zig");
const expandRequireContextRecords = graph_require_context.expandRecords;
const graph_import_usage = @import("import_usage.zig");
const graph_requested_exports = @import("requested_exports.zig");

fn appendResolvedDep(
    self: *ModuleGraph,
    mod_idx: usize,
    dep: CachedResolvedDep,
) !void {
    const mod_ptr = self.modules.at(mod_idx);
    const path_owned = try self.allocator.dupe(u8, dep.path);
    errdefer self.allocator.free(path_owned);

    var owned_dep = dep;
    owned_dep.path = path_owned;
    try mod_ptr.resolved_deps.append(self.allocator, owned_dep);
}

pub fn replayCachedResolvedDeps(self: *ModuleGraph, mod_idx: usize) !void {
    std.debug.assert(mod_idx < self.modules.count());
    const mod_index = ModuleIndex.fromUsize(mod_idx);
    const mod_ptr = self.modules.at(mod_idx);

    for (mod_ptr.resolved_deps.items) |dep| {
        switch (dep.target) {
            .file, .virtual => {
                const dep_idx = try self.addModule(dep.path);
                if (dep.target_is_module_field or mod_ptr.is_module_field) {
                    self.modules.at(@intFromEnum(dep_idx)).is_module_field = true;
                }
                if (dep.is_context_dep) {
                    self.modules.at(@intFromEnum(dep_idx)).is_context_dep = true;
                }
                try replayLinkResolvedDep(self, mod_index, mod_idx, dep, dep_idx);
            },
            .disabled => {
                const dep_idx = try self.addDisabledModule(dep.path);
                try replayLinkResolvedDep(self, mod_index, mod_idx, dep, dep_idx);
            },
            .external => {
                const ext_idx = try self.addExternalModule(dep.path);
                if (dep.record_index) |rec_idx| {
                    if (rec_idx < mod_ptr.import_records.len) {
                        mod_ptr.import_records[rec_idx].is_external = true;
                        _ = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_idx, mod_ptr.import_records[rec_idx], ext_idx);
                    }
                }
                if (dep.kind == .dynamic_import) {
                    try self.linkDynamicImport(mod_index, ext_idx);
                } else {
                    try self.linkDependency(mod_index, ext_idx);
                }
            },
            .worker => {
                const rec_idx = dep.record_index orelse continue;
                const path_dupe = try self.allocator.dupe(u8, dep.path);
                try self.worker_entries.append(self.allocator, .{
                    .resolved_path = path_dupe,
                    .source_module = mod_index,
                    .record_index = @intCast(rec_idx),
                });
            },
        }
    }
}

/// `record_index` 가 있으면 record 갱신 + link, 없으면 link 만 수행. file/virtual/disabled
/// 케이스가 공통으로 사용. external 은 `is_external` flag 기록 후 무조건 link 라 별도.
fn replayLinkResolvedDep(
    self: *ModuleGraph,
    mod_index: ModuleIndex,
    mod_idx: usize,
    dep: CachedResolvedDep,
    dep_idx: ModuleIndex,
) !void {
    if (dep.record_index) |rec_idx| {
        const mod_ptr = self.modules.at(mod_idx);
        if (rec_idx >= mod_ptr.import_records.len) return;
        const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_idx, mod_ptr.import_records[rec_idx], dep_idx);
        try recordResolvedDep(self, mod_index, mod_idx, rec_idx, dep_idx, dep.kind);
        if (request_changed) try resolveDeferredRequestedImportsIfReady(self, dep_idx);
        return;
    }
    _ = try graph_requested_exports.requestAll(self, dep_idx);
    if (dep.kind == .dynamic_import) {
        try self.linkDynamicImport(mod_index, dep_idx);
    } else {
        try self.linkDependency(mod_index, dep_idx);
    }
}

/// context_expansion_deps 를 resolve 하고 graph 에 module + dependency 로 등록 (#1579 Phase 4).
/// scanModules receiver / resolveModuleImports 양쪽 경로에서 호출. SegmentedList 로
/// append 해도 기존 *Module 포인터는 유효 (#1779 INVARIANTS.md).
pub fn applyContextDepResults(self: *ModuleGraph, mod_idx: usize) !void {
    const mod_index = ModuleIndex.fromUsize(mod_idx);
    const mod_ptr = self.modules.at(mod_idx);
    const context_deps = mod_ptr.context_expansion_deps;
    if (context_deps.len == 0) return;

    const module_path = mod_ptr.path;
    const source_dir = std.fs.path.dirname(module_path) orelse ".";
    for (context_deps) |dep| {
        const resolved = self.resolve_cache.resolveThreadSafe(source_dir, dep.specifier, dep.kind) catch |err| switch (err) {
            error.ModuleNotFound => {
                self.addDiag(
                    .unresolved_import,
                    .warning,
                    module_path,
                    dep.span,
                    .resolve,
                    "Cannot resolve require.context match",
                    dep.specifier,
                );
                continue;
            },
            else => |e| return e,
        };
        if (resolved) |m| switch (m) {
            .file => |f| {
                defer self.allocator.free(f.path);
                const dep_idx = try self.addModule(f.path);
                _ = try graph_requested_exports.requestAll(self, dep_idx);
                // tree-shaker 가 static import 없이도 이 모듈을 보존하도록 마킹.
                self.modules.at(@intFromEnum(dep_idx)).is_context_dep = true;
                try appendResolvedDep(self, mod_idx, .{
                    .kind = dep.kind,
                    .target = .file,
                    .path = f.path,
                    .target_is_module_field = f.is_module_field,
                    .is_context_dep = true,
                });
                try self.linkDependency(mod_index, dep_idx);
            },
            // require.context 의 disabled / virtual 등 variant 는 Phase 1 cache 에서 반환되지 않음.
            .disabled => |d| self.allocator.free(d.path),
            .virtual, .dataurl, .external, .custom => unreachable,
        };
    }
}

/// 의존성 인덱스를 import_records 에 기록하고 graph 에 link.
/// dynamic_import 는 별도 link 경로 — 그 외는 일반 dependency.
/// SegmentedList 는 realloc 없지만 모듈 소유 slice 를 update 하므로 *Module 재조회 안전.
fn recordResolvedDep(
    self: *ModuleGraph,
    mod_index: ModuleIndex,
    mod_idx: usize,
    rec_i: usize,
    dep_idx: ModuleIndex,
    kind: types.ImportKind,
) !void {
    const src_mod = self.modules.at(mod_idx);
    src_mod.import_records[rec_i].resolved = dep_idx;
    src_mod.import_records[rec_i].is_lazy_resolved = false;
    if (kind == .dynamic_import) {
        try self.linkDynamicImport(mod_index, dep_idx);
    } else {
        try self.linkDependency(mod_index, dep_idx);
    }
}

pub fn applyResolveResult(
    self: *ModuleGraph,
    mod_idx: usize,
    rec_i: usize,
    record: types.ImportRecord,
    resolved: ?plugin_mod.ResolvedModule,
    is_error: bool,
) !void {
    const mod_index = ModuleIndex.fromUsize(mod_idx);
    if (is_error) {
        // Worker resolve 실패 → 경고만 (메인 빌드 중단하지 않음)
        if (record.kind == .worker) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Cannot resolve worker module", record.specifier);
            return;
        }
        // ModuleNotFound — browser에서 Node 빌트인은 빈 CJS로 대체
        if (self.resolve_cache.platform.isBrowserLike() and resolve_cache_mod.isNodeBuiltin(record.specifier)) {
            const dep_idx = try self.addDisabledModule(record.specifier);
            try appendResolvedDep(self, mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .disabled,
                .path = record.specifier,
            });
            try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            return;
        }
        // try-block 안의 optional require/import — warning + stub.
        // follow-redirects/debug.js 의 silent-catch 패턴 같이 unresolved 가
        // runtime 에 catch 되는 의도된 케이스를 build hard-fail 시키지 않는다.
        if (record.is_optional) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Optional dependency not resolved (will throw at runtime if reached)", record.specifier);
            const dep_idx = try self.addDisabledModule(record.specifier);
            try appendResolvedDep(self, mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .disabled,
                .path = record.specifier,
            });
            try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            return;
        }
        // #2466 implicit type-only import — `react-native-screens/types` 처럼 .d.ts 만
        // 있는 subpath 를 `import { X } from '...'` 로 가져와 X 를 type position 에서만
        // 쓰는 패턴. babel typescript preset 은 transform 시 statement 통째 제거하므로
        // Metro 는 resolve 시도조차 안 함. ZNTC 는 parser 가 type annotation 을 폐기
        // 해서 analyzer 가 type-position reference 를 못 보지만, 그게 오히려 도움 —
        // value position 참조가 0 이면 (truly unused 이거나 type-only) 어느 경우든
        // bundle 에서 빠져도 동작 동등. resolve 실패 + binding 전부 value-use 없음 →
        // soft fail (warning + stub).
        if (record.kind == .static_import and graph_import_usage.isImportAllBindingsUnused(self, self.modules.at(mod_idx), record)) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Type-only import elided (no value usage)", record.specifier);
            const dep_idx = try self.addDisabledModule(record.specifier);
            try appendResolvedDep(self, mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .disabled,
                .path = record.specifier,
            });
            try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            return;
        }
        const sev: types.BundlerDiagnostic.Severity = if (record.kind == .dynamic_import) .warning else .@"error";
        self.addDiag(.unresolved_import, sev, self.modules.at(mod_idx).path, record.span, .resolve, "Cannot resolve module", record.specifier);
        return;
    }

    if (resolved) |m| {
        // Phase 1 의 cache 와 plugin (fromLegacy 통과) 는 file/disabled variant 만 반환.
        // virtual/dataurl/external/custom 은 PR 5 plugin layer 도입 시 처리.
        switch (m) {
            .file => |f| {
                defer self.allocator.free(f.path);

                // Worker: 메인 그래프에 모듈로 추가하지 않고 경로만 수집
                if (record.kind == .worker) {
                    const path_dupe = try self.allocator.dupe(u8, f.path);
                    try self.worker_entries.append(self.allocator, .{
                        .resolved_path = path_dupe,
                        .source_module = @enumFromInt(mod_idx),
                        .record_index = @intCast(rec_i),
                    });
                    try appendResolvedDep(self, mod_idx, .{
                        .record_index = @intCast(rec_i),
                        .kind = record.kind,
                        .target = .worker,
                        .path = f.path,
                        .target_is_module_field = f.is_module_field,
                    });
                    return;
                }

                const dep_idx = try self.addModule(f.path);
                if (f.is_module_field or self.modules.at(mod_idx).is_module_field) {
                    self.modules.at(@intFromEnum(dep_idx)).is_module_field = true;
                }
                const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, dep_idx);
                try appendResolvedDep(self, mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .file,
                    .path = f.path,
                    .target_is_module_field = f.is_module_field,
                });
                try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
                if (request_changed) try resolveDeferredRequestedImportsIfReady(self, dep_idx);
            },
            .disabled => |d| {
                defer self.allocator.free(d.path);
                const dep_idx = try self.addDisabledModule(record.specifier);
                _ = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, dep_idx);
                try appendResolvedDep(self, mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .disabled,
                    .path = record.specifier,
                });
                try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            },
            .virtual => |v| {
                // #1961: virtual module 은 plugin 의 load 훅이 source 채움. addModule 이
                // path 를 dupe 하므로 graph 가 owner. v.path 는 plugin 이 borrow 한
                // specifier (runtime_helper_modules) 일 수 있어 free 안 함 — plugin 이
                // alloc 했으면 plugin context lifetime 동안 살아있어야 한다는 규약.
                const dep_idx = try self.addModule(v.path);
                const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, dep_idx);
                try appendResolvedDep(self, mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .virtual,
                    .path = v.path,
                });
                try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
                if (request_changed) try resolveDeferredRequestedImportsIfReady(self, dep_idx);
            },
            .dataurl, .external, .custom => unreachable,
        }
    } else {
        // external — phantom Module 로 graph 에 등록 + 양방향 link.
        // 핵심 정책: `record.resolved` 는 `.none` 그대로 둔다. emit/linker 의 기존
        // `rec.resolved.isNone()` 외부 검출 코드를 깨지 않으면서 ModuleInfo /
        // graph traversal 에서만 phantom 노드가 보이도록 분리.
        const ext_idx = try self.addExternalModule(record.specifier);
        const src_mod = self.modules.at(mod_idx);
        src_mod.import_records[rec_i].is_external = true;
        src_mod.import_records[rec_i].is_lazy_resolved = false;
        _ = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, ext_idx);
        try appendResolvedDep(self, mod_idx, .{
            .record_index = @intCast(rec_i),
            .kind = record.kind,
            .target = .external,
            .path = record.specifier,
        });
        if (record.kind == .dynamic_import) {
            try self.linkDynamicImport(mod_index, ext_idx);
        } else {
            try self.linkDependency(mod_index, ext_idx);
        }
    }
}

pub fn resolveDeferredRequestedImportsIfReady(self: *ModuleGraph, idx: ModuleIndex) anyerror!void {
    if (idx.isNone()) return;
    const mod_idx = idx.toUsize();
    if (mod_idx >= self.modules.count()) return;
    const m = self.modules.at(mod_idx);
    if (m.state != .ready or m.is_external or m.is_disabled) return;
    if (!graph_requested_exports.hasDeferredRequestedImports(self, mod_idx)) return;
    try resolveModuleImports(self, idx);
}

/// Phase 1: 모듈의 import들을 resolve하고 의존성 모듈을 등록한다.
/// modules 배열이 커질 수 있으므로, 포인터가 아닌 인덱스로만 접근.
pub fn resolveModuleImports(self: *ModuleGraph, idx: ModuleIndex) !void {
    const mod_idx = @intFromEnum(idx);
    if (mod_idx >= self.modules.count()) return;

    const mod_ptr = self.modules.at(mod_idx);
    const module_path = mod_ptr.path;
    const source_dir = std.fs.path.dirname(module_path) orelse ".";

    // Plugin: resolveId 훅용 runner를 루프 밖에서 한 번만 생성
    const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

    // import.meta.glob: glob 레코드를 파일 시스템에서 확장
    expandGlobRecords(self.allocator, mod_ptr.import_records, source_dir);
    // require.context: plugin 으로 matches 주입 + context_expansion_deps 로 수집 (#1579 Phase 4).
    expandRequireContextRecords(self, mod_idx);

    const records = mod_ptr.import_records;
    for (records, 0..) |record, rec_i| {
        if (record.kind == .glob) continue;
        if (record.kind == .require_context) continue;
        if (record.resolved != .none or record.is_external) continue;
        const should_link = graph_requested_exports.shouldLinkResolvedRecordForModule(self, mod_idx, rec_i, record);

        // Plugin: resolveId 훅 — 기본 resolver 전에 플러그인에게 경로 해석 기회를 줌
        if (plugin_runner) |runner| {
            if (self.shouldRunResolveId(record.specifier)) {
                var hook_ctx: plugin_mod.HookContext = .{};
                const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator, &hook_ctx) catch |err| switch (err) {
                    error.PluginFailed => {
                        self.addPluginFailureDiag(hook_ctx.failure, module_path, record.span, .resolve);
                        return;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                // non-null이면 플러그인이 resolve 완료 → 기본 resolver 건너뜀
                if (resolve_result) |plugin_result| {
                    if (should_link) {
                        try applyResolveResult(self, mod_idx, rec_i, record, plugin_result, false);
                    } else {
                        self.markRecordLazyResolved(mod_idx, rec_i);
                        self.discardResolvedModule(plugin_result);
                    }
                    continue;
                }
                // null이면 기본 resolver로 fall through
            }
        }

        const resolved = self.resolve_cache.resolve(
            source_dir,
            record.specifier,
            record.kind,
        ) catch |err| switch (err) {
            error.ModuleNotFound => {
                try applyResolveResult(self, mod_idx, rec_i, record, null, true);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (should_link) {
            try applyResolveResult(self, mod_idx, rec_i, record, resolved, false);
        } else if (resolved) |resolved_module| {
            self.markRecordLazyResolved(mod_idx, rec_i);
            self.discardResolvedModule(resolved_module);
        }
    }

    // require.context context_expansion_deps 도 resolve + addDep.
    try applyContextDepResults(self, mod_idx);
}
