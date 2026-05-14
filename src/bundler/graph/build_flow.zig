//! Build orchestration and incremental rebuild flow for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const runtime_polyfills = @import("../runtime_polyfills.zig");
const module_store = @import("../module_store.zig");
const fs = @import("../fs.zig");
const MpscChannel = @import("../mpsc_channel.zig").MpscChannel;
const profile = @import("../../profile.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const graph_plugins = @import("plugins.zig");
const graph_project_root = @import("project_root.zig");
const graph_requested_exports = @import("requested_exports.zig");
const graph_runtime_polyfills = @import("runtime_polyfills.zig");
const graph_discovery_scan = @import("discovery_scan.zig");
const graph_resolve_imports = @import("resolve_imports.zig");
const graph_cycles = @import("cycles.zig");
const graph_finalize = @import("finalize.zig");

/// 진입점들로부터 모듈 그래프를 구축한다.
/// Phase 1: 모든 모듈 등록 + 파싱 + import resolve (BFS)
/// Phase 2: DFS로 exec_index + 순환 감지
pub fn build(self: *ModuleGraph, entry_points: []const []const u8) !void {
    // #1961: ZNTC builtin runtime helper plugin 을 plugin slice 앞에 prepend.
    // 워커 스레드에서 호출하기 전 단일 thread 진입점에서 1회만.
    graph_plugins.ensureBuiltinPlugins(self);

    // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용)
    if (self.entry_dir.len == 0 and entry_points.len > 0) {
        self.entry_dir = std.fs.path.dirname(entry_points[0]) orelse "";
    }
    // project_root 자동 감지 (미지정 시): entry_dir에서 위로 올라가며 첫 package.json
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, self.entry_dir) catch self.entry_dir;
    }

    // --inject 파일을 먼저 모듈 그래프에 추가
    var inject_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer inject_indices.deinit(self.allocator);
    for (self.inject_files) |inject_path| {
        const idx = try self.addModule(inject_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try inject_indices.append(self.allocator, idx);
    }

    // --run-before-main 파일도 graph root 로 먼저 등록하되, 엔트리 연결은
    // runtime-polyfill root 선별 이후에 수행한다.
    var run_before_main_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer run_before_main_indices.deinit(self.allocator);
    for (self.run_before_main_files) |rbm_path| {
        const idx = try self.addModule(rbm_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try run_before_main_indices.append(self.allocator, idx);
    }

    // Phase 1: 이벤트 큐 기반 스캔 (esbuild 스타일).
    // 워커: parseModule + resolve → 채널 send (그래프 변형 없음)
    // 메인: 채널 recv → 결과 적용 + addModule → 즉시 새 워커 스폰
    // 배치 경계 없이 모듈 발견 즉시 파싱 시작 → CPU 유휴 시간 최소화.
    var discover_scope = profile.begin(.graph_discover);
    for (entry_points) |entry_path| {
        const idx = try self.addModule(entry_path);
        _ = try graph_requested_exports.requestAll(self, idx);
    }

    var spawned_up_to: usize = 0;
    if (self.max_threads == 0 and self.modules.count() == 1) {
        // Tiny graphs spend more time opening the pool/channel than scanning the first batch.
        // Keep the initial bounded batch on the main thread, then fall back to the pool if it
        // discovers more work.
        spawned_up_to = try graph_discovery_scan.scanModuleRangeSequential(self, 0, 1);
        const pending_after_entry = self.modules.count() - spawned_up_to;
        if (pending_after_entry > 0 and pending_after_entry <= 16) {
            spawned_up_to = try graph_discovery_scan.scanModuleRangeSequential(self, spawned_up_to, self.modules.count());
        }
    }

    if (spawned_up_to < self.modules.count()) {
        var pool: std.Thread.Pool = undefined;
        const pool_opts: std.Thread.Pool.Options = if (self.max_threads > 0)
            .{ .allocator = self.allocator, .n_jobs = self.max_threads }
        else
            .{ .allocator = self.allocator };
        const pool_ok = if (pool.init(pool_opts)) |_| true else |_| false;
        defer if (pool_ok) pool.deinit();

        if (!pool_ok) {
            try discoverPendingModulesSequential(self, spawned_up_to);
        } else {
            var channel = MpscChannel(graph_discovery_scan.ScanResult).init(self.allocator);
            defer channel.deinit();

            var inflight: usize = 0;

            // Spawn the initial modules: entries, inject files, and run-before-main files.
            while (spawned_up_to < self.modules.count()) : (spawned_up_to += 1) {
                const m = self.modules.at(spawned_up_to);
                if (m.state == .ready) continue; // Skip disabled modules.
                const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                pool.spawn(graph_discovery_scan.scanWorker, .{ self, idx, &channel }) catch {
                    // Fall back to the main thread if the pool cannot spawn this job.
                    graph_discovery_scan.scanWorker(self, idx, &channel);
                };
                inflight += 1;
            }

            // Apply each worker result, then immediately dispatch newly discovered modules.
            while (inflight > 0) {
                const result = channel.recv();
                inflight -= 1;
                try graph_discovery_scan.applyScanResult(self, result);

                // Dispatch newly discovered modules without waiting for a batch boundary.
                while (spawned_up_to < self.modules.count()) : (spawned_up_to += 1) {
                    const m = self.modules.at(spawned_up_to);
                    if (m.state == .ready) continue;
                    const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                    pool.spawn(graph_discovery_scan.scanWorker, .{ self, idx, &channel }) catch {
                        graph_discovery_scan.scanWorker(self, idx, &channel);
                    };
                    inflight += 1;
                }
            }
        }
    }

    var runtime_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer runtime_indices.deinit(self.allocator);
    try applyRuntimePolyfills(self, &runtime_indices);
    try linkExecutionRoots(self, entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);
    discover_scope.end();

    try finalizeGraph(self, entry_points);
}

fn applyRuntimePolyfills(self: *ModuleGraph, runtime_indices: *std.ArrayList(ModuleIndex)) !void {
    const plan = self.runtime_polyfills orelse return;

    var scope = profile.begin(.graph_runtime_polyfills);
    defer scope.end();

    var selected: std.ArrayList(runtime_polyfills.ResolvedModule) = .empty;
    defer selected.deinit(self.allocator);
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();

    switch (plan.mode) {
        .entry => {
            var aggregate_scope = profile.begin(.graph_runtime_polyfills_aggregate);
            defer aggregate_scope.end();
            for (plan.entry_modules) |module| {
                try graph_runtime_polyfills.selectModule(self.allocator, &selected, &seen, plan, module, "entry");
            }
        },
        .usage => {
            var used: runtime_polyfills.FeatureSet = .{};
            defer used.deinit(self.allocator);
            {
                var aggregate_scope = profile.begin(.graph_runtime_polyfills_aggregate);
                defer aggregate_scope.end();
                const count = self.modules.count();
                for (0..count) |i| {
                    const m = self.modules.at(i);
                    var collect_scope = profile.begin(.graph_runtime_polyfills_collect);
                    var module_usage = try runtime_polyfills.collectModuleUsage(self.allocator, m);
                    defer module_usage.deinit(self.allocator);
                    collect_scope.end();
                    if (!module_usage.isEmpty()) graph_runtime_polyfills.logUsage(m.path, module_usage);
                    try used.merge(self.allocator, module_usage);
                }
            }
            for (plan.candidates) |candidate| {
                const module: runtime_polyfills.ResolvedModule = .{
                    .module = candidate.module,
                    .path = candidate.path,
                };
                if (used.has(candidate.feature)) {
                    try graph_runtime_polyfills.selectModule(self.allocator, &selected, &seen, plan, module, candidate.feature);
                } else {
                    graph_runtime_polyfills.logUnusedCandidate(candidate);
                }
            }
        },
    }

    for (plan.include) |module| {
        try graph_runtime_polyfills.selectModule(self.allocator, &selected, &seen, plan, module, "include");
    }

    if (selected.items.len == 0) return;

    var inject_scope = profile.begin(.graph_runtime_polyfills_inject);
    defer inject_scope.end();
    const discover_start = self.modules.count();
    for (selected.items) |module| {
        const idx = try self.addModule(module.path);
        _ = try graph_requested_exports.requestAll(self, idx);
        if (self.moduleAtMut(idx)) |m| {
            m.is_context_dep = true;
        }
        try runtime_indices.append(self.allocator, idx);
        try self.runtime_polyfill_roots.append(self.allocator, module.path);
        graph_runtime_polyfills.logPrelude(plan, module);
    }
    try discoverPendingModulesSequential(self, discover_start);
}

fn discoverPendingModulesSequential(self: *ModuleGraph, start_index: usize) !void {
    var parse_start = start_index;
    while (parse_start < self.modules.count()) {
        const parse_end = self.modules.count();
        for (parse_start..parse_end) |j| {
            const m = self.modules.at(j);
            if (m.state == .ready) continue;
            self.parseModule(@enumFromInt(@as(u32, @intCast(j))));
        }
        for (parse_start..parse_end) |i| {
            const m_ptr = self.modules.at(i);
            if (m_ptr.state == .ready) continue;
            self.applySideEffectsFromPackageJson(m_ptr);
            m_ptr.state = .ready;
        }
        for (parse_start..parse_end) |i| {
            const m_ptr = self.modules.at(i);
            if (m_ptr.is_disabled or m_ptr.is_external) continue;
            try graph_resolve_imports.resolveModuleImports(self, @enumFromInt(@as(u32, @intCast(i))));
            try graph_resolve_imports.applyContextDepResults(self, i);
        }
        parse_start = parse_end;
    }
}

fn linkExecutionRoots(
    self: *ModuleGraph,
    entry_points: []const []const u8,
    inject_indices: []const ModuleIndex,
    runtime_indices: []const ModuleIndex,
    run_before_main_indices: []const ModuleIndex,
) !void {
    if (inject_indices.len == 0 and runtime_indices.len == 0 and run_before_main_indices.len == 0) return;
    for (entry_points) |entry_path| {
        const entry_idx = self.path_to_module.get(entry_path) orelse continue;
        const ei = @intFromEnum(entry_idx);
        if (ei >= self.modules.count()) continue;
        for (inject_indices) |inject_idx| try linkDependencyUnique(self, entry_idx, inject_idx);
        for (runtime_indices) |runtime_idx| try linkDependencyUnique(self, entry_idx, runtime_idx);
        for (run_before_main_indices) |rbm_idx| try linkDependencyUnique(self, entry_idx, rbm_idx);
    }
}

fn linkDependencyUnique(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void {
    if (to.isNone()) return;
    const from_mod = self.getModule(from) orelse return;
    for (from_mod.dependencies.items) |existing| {
        if (existing == to) return;
    }
    try self.linkDependency(from, to);
}

/// Phase 2-4: DFS exec_index + ExportsKind 승격 + TLA 전파.
/// build()와 buildIncremental() 양쪽에서 호출.
fn finalizeGraph(self: *ModuleGraph, entry_points: []const []const u8) !void {
    var scope = profile.begin(.graph_finalize);
    defer scope.end();

    const count = self.modules.count();
    if (count == 0) return;

    var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
    defer visited.deinit();
    var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
    defer in_stack.deinit();

    var entry_indices: std.ArrayList(ModuleIndex) = .empty;
    defer entry_indices.deinit(self.allocator);
    for (entry_points) |entry_path| {
        if (self.path_to_module.get(entry_path)) |idx| {
            const ei = @intFromEnum(idx);
            if (ei < self.modules.count()) {
                self.modules.at(ei).is_entry_point = true;
            }
            try graph_cycles.dfs(self, idx, &visited, &in_stack);
            try entry_indices.append(self.allocator, idx);
        }
    }

    // dfs 는 dependencies 만 따라가서 exec_index/TLA 분석 정확. dynamic edge 통한
    // static cycle 멤버 marking 은 별도 pass (#2211).
    try graph_cycles.markViaDynamic(self, entry_indices.items);

    graph_finalize.promoteExportsKinds(self);
    graph_finalize.promoteRunBeforeMainModules(self);
    graph_finalize.registerWrapperSymbols(self);
    graph_finalize.propagateTopLevelAwait(self);
    checkSelfReExport(self);
}

/// Self-cycle named re-export 진단. alias/onResolve가 source를 자기 자신으로
/// redirect하면 emit이 `exports_self.X` 자기 참조 getter를 생성해 평가 시 무한
/// 재귀. rolldown CIRCULAR_REEXPORT처럼 빌드 단계에서 거부. default re-export는
/// 별도 경로에서 이미 안전 처리되므로 제외.
fn checkSelfReExport(self: *ModuleGraph) void {
    var it = self.modules.iterator(0);
    var i: usize = 0;
    while (it.next()) |m| : (i += 1) {
        const self_idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export) continue;
            if (std.mem.eql(u8, eb.exported_name, "default")) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= m.import_records.len) continue;
            if (m.import_records[rec_idx].resolved != self_idx) continue;
            self.addDiag(
                .circular_reexport,
                .@"error",
                m.path,
                eb.local_span,
                .link,
                "Re-export source resolves to the module itself (self-cycle)",
                "Check resolver alias / plugin onResolve — the import source must point to a different module.",
            );
        }
    }
}

/// 증분 빌드 결과.
pub const IncrementalBuildResult = struct {
    /// 그래프 구조 또는 내용이 변경되었는지
    graph_changed: bool,
    /// 재파싱된 모듈 인덱스 목록 (graph allocator 소유)
    reparsed_indices: []const types.ModuleIndex,
};

/// 증분 그래프 빌드. store에서 캐시 히트된 모듈은 파싱 스킵.
/// 캐시 미스된 모듈만 parseModule()을 실행한다.
/// build()와 동일한 Phase 2~4를 실행하여 exec_index, ExportsKind, TLA를 보장.
pub fn buildIncremental(
    self: *ModuleGraph,
    entry_points: []const []const u8,
    store: *module_store.PersistentModuleStore,
    /// Watcher 가 이번 rebuild 동안 변경됐다고 보고한 절대경로 set.
    /// null → 현재 변경 정보 없음 (initial build / CLI 모드). 전체 모듈 stat.
    /// non-null → set 에 없는 path 는 mtime stat 을 skip 하고 store 의 cached mtime 을 그대로 신뢰.
    /// 새로 그래프에 추가된 모듈 (`store.modules.contains(path) == false`) 은 강제로 stat (Issue #1727 §3).
    changed_files: ?*const std.StringHashMap(void),
) !IncrementalBuildResult {
    // #1961: builtin runtime helper plugin prepend (build() 와 동일).
    graph_plugins.ensureBuiltinPlugins(self);

    // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용)
    if (self.entry_dir.len == 0 and entry_points.len > 0) {
        self.entry_dir = std.fs.path.dirname(entry_points[0]) orelse "";
    }
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, self.entry_dir) catch self.entry_dir;
    }

    // --inject 파일을 먼저 모듈 그래프에 추가
    var inject_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer inject_indices.deinit(self.allocator);
    for (self.inject_files) |inject_path| {
        const idx = try self.addModule(inject_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try inject_indices.append(self.allocator, idx);
    }

    var run_before_main_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer run_before_main_indices.deinit(self.allocator);
    for (self.run_before_main_files) |rbm_path| {
        const idx = try self.addModule(rbm_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try run_before_main_indices.append(self.allocator, idx);
    }

    for (entry_points) |entry_path| {
        const idx = try self.addModule(entry_path);
        _ = try graph_requested_exports.requestAll(self, idx);
    }

    var reparsed: std.ArrayListUnmanaged(types.ModuleIndex) = .empty;
    var graph_changed = false;
    var cache_hit_modules = std.AutoHashMap(u32, void).init(self.allocator);
    defer cache_hit_modules.deinit();

    var discover_scope = profile.begin(.graph_discover);

    // 순차 처리 — 증분 빌드는 캐시 히트가 대부분이므로 스레드 풀 오버헤드보다 효율적.
    var parse_start: usize = 0;
    while (parse_start < self.modules.count()) {
        const parse_end = self.modules.count();
        for (parse_start..parse_end) |i| {
            var mod = self.modules.at(i);
            if (mod.state == .ready) continue; // disabled 모듈 등

            const mod_path = mod.path;

            // Watcher-driven mtime skip (Issue #1727 §3): watcher 가 이 파일을 건드리지
            // 않았다고 보고했고 cache 에도 있으면 stat syscall 을 생략하고 cached mtime 을
            // 그대로 쓴다. 수백 모듈 × ~100us stat 이 주 병목이었음. changed_files 가 null
            // 이거나 cache miss 인 경로는 기존처럼 stat.
            const mtime: i128 = blk: {
                if (changed_files) |cf| {
                    if (!cf.contains(mod_path)) {
                        if (store.modules.get(mod_path)) |cached_entry| {
                            break :blk cached_entry.mtime;
                        }
                    }
                }
                break :blk getMtime(mod_path) catch 0;
            };

            // 캐시 조회
            if (store.getIfFresh(mod_path, mtime)) |cached| {
                // 캐시 히트: struct assign으로 전체 복원 후 graph-specific 필드만 override.
                // Module에 새 필드가 추가되어도 누락 없이 복사됨.
                const saved_index = mod.index;
                const saved_path = mod.path;
                const saved_deps = mod.dependencies;
                const saved_importers = mod.importers;
                const saved_dynamic = mod.dynamic_imports;
                const saved_dynamic_importers = mod.dynamic_importers;
                mod.* = cached.module;
                mod.index = saved_index;
                mod.path = saved_path;
                mod.dependencies = saved_deps;
                mod.importers = saved_importers;
                mod.dynamic_imports = saved_dynamic;
                mod.dynamic_importers = saved_dynamic_importers;
                mod.mtime = mtime;
                try cache_hit_modules.put(@intCast(i), {});
                // parse_arena 소유권 이전: store → graph.
                cached.module.parse_arena = null;
                cached.module.resolve_dir = null;
                cached.module.import_records = &.{};
                cached.module.resolved_deps = .empty;
                // alias_table 도 동일 패턴: 얕은 복사로 인해 backing 이
                // graph 와 store 에 동시에 잡혀있어 graph.deinit 에서 free 되면
                // store 쪽 포인터가 dangling — 다음 rebuild 가 그 메모리를
                // nested_name_sets HashMap backing 으로 재사용하면
                // setCanonicalName 의 write 가 Header 를 덮어써 deinit 시
                // malloc abort. ownership 을 graph 로 이전해 graph.deinit
                // 한 번만 free 되도록 한다.
                cached.module.alias_table = null;
                // canonical_name 은 이전 Build 의 Linker 가 소유한 문자열을
                // 가리키는데, 그 Linker.deinit 이후 이미 freed 상태다.
                // 다음 Linker 가 conflict 마다 새로 assign 하므로 stale 한
                // 포인터를 비워 emit 이 freed memory 를 읽지 못하도록 한다.
                if (mod.semantic) |*sem| {
                    for (sem.symbols.items) |*sym| sym.canonical_name = "";
                }
                mod.state = .ready;
            } else {
                // 캐시 미스: 정상 파싱
                self.parseModule(@enumFromInt(@as(u32, @intCast(i))));
                const m_ptr = self.modules.at(i);
                self.applySideEffectsFromPackageJson(m_ptr);
                m_ptr.mtime = mtime;
                m_ptr.state = .ready;
                try reparsed.append(self.allocator, @enumFromInt(@as(u32, @intCast(i))));
            }
        }

        // resolve + addModule (새 의존성 등록)
        for (parse_start..parse_end) |i| {
            if (cache_hit_modules.contains(@intCast(i))) {
                try graph_resolve_imports.replayCachedResolvedDeps(self, i);
                try graph_resolve_imports.resolveDeferredRequestedImportsIfReady(self, ModuleIndex.fromUsize(i));
            } else {
                try graph_resolve_imports.resolveModuleImports(self, @enumFromInt(@as(u32, @intCast(i))));
            }
        }

        // 새 모듈이 추가되었으면 그래프 변경
        if (self.modules.count() > parse_end) {
            graph_changed = true;
        }
        parse_start = parse_end;
    }

    var runtime_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer runtime_indices.deinit(self.allocator);
    const before_runtime_count = self.modules.count();
    try applyRuntimePolyfills(self, &runtime_indices);
    if (self.modules.count() > before_runtime_count) graph_changed = true;
    try linkExecutionRoots(self, entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);

    discover_scope.end();

    try finalizeGraph(self, entry_points);

    return .{
        .graph_changed = graph_changed or reparsed.items.len > 0,
        .reparsed_indices = try reparsed.toOwnedSlice(self.allocator),
    };
}

/// 파일의 mtime 을 나노초로 반환. virtual module / embedded null byte / overlong
/// path 는 error 로 폴백해 호출부가 `catch 0` 으로 처리하도록 한다.
///
/// `std.fs.Dir.statFile` 은 내부에서 `toPosixPath` 를 거치는데, 그 함수가
/// `runtime_safety` (Debug / ReleaseSafe) 빌드에서 path 내 null byte 존재 시
/// `assert(indexOfScalar == null)` 로 panic (reached unreachable code) 한다.
/// plugin 이 합성한 virtual path, AssetRegistry 등 에서 실제로 이런 path 가 들어와
/// HMR rebuild 중 번들러가 통째로 죽던 버그를 막는다.
pub fn getMtime(path: []const u8) !i128 {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len >= std.fs.max_path_bytes) return error.NameTooLong;
    const stat = try fs.statFile(path);
    return stat.mtime;
}
