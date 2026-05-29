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
const renumber = @import("renumber.zig");
const graph_resolve_imports = @import("resolve_imports.zig");
const graph_cycles = @import("cycles.zig");
const graph_finalize = @import("finalize.zig");

/// 진입점들로부터 모듈 그래프를 구축한다.
/// Phase 1: 모든 모듈 등록 + 파싱 + import resolve (BFS)
/// Phase 2: DFS로 exec_index + 순환 감지
pub fn build(self: *ModuleGraph, io: std.Io, entry_points: []const []const u8) !void {
    // #1961: ZNTC builtin runtime helper plugin 을 plugin slice 앞에 prepend.
    // 워커 스레드에서 호출하기 전 단일 thread 진입점에서 1회만.
    graph_plugins.ensureBuiltinPlugins(self);

    // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용).
    // esbuild `outbase` 자동 추론과 동치 — 모든 entry 의 dirname 의 longest
    // common parent.
    if (entry_points.len > 0) {
        self.entry_dir = computeEntryDir(entry_points);
    }
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, io, self.entry_dir) catch self.entry_dir;
    }

    // --inject 파일을 먼저 모듈 그래프에 추가
    var inject_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer inject_indices.deinit(self.allocator);
    for (self.inject_files) |inject_path| {
        const idx = try self.addModule(io, inject_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try inject_indices.append(self.allocator, idx);
    }

    // --run-before-main 파일도 graph root 로 먼저 등록하되, 엔트리 연결은
    // runtime-polyfill root 선별 이후에 수행한다.
    var run_before_main_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer run_before_main_indices.deinit(self.allocator);
    for (self.run_before_main_files) |rbm_path| {
        const idx = try self.addModule(io, rbm_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try run_before_main_indices.append(self.allocator, idx);
    }

    // Phase 1: 이벤트 큐 기반 스캔 (esbuild 스타일).
    // 워커: parseModule + resolve → 채널 send (그래프 변형 없음)
    // 메인: 채널 recv → 결과 적용 + addModule → 즉시 새 워커 스폰
    // 배치 경계 없이 모듈 발견 즉시 파싱 시작 → CPU 유휴 시간 최소화.
    var discover_scope = profile.begin(.graph_discover);
    for (entry_points) |entry_path| {
        const idx = try self.addModule(io, entry_path);
        _ = try graph_requested_exports.requestAll(self, idx);
    }

    var spawned_up_to: usize = 0;
    if (self.max_threads == 0 and self.modules.count() == 1) {
        // Tiny graphs spend more time opening the channel than scanning the first batch.
        // Keep the initial bounded batch on the main thread, then fall back to async if it
        // discovers more work.
        spawned_up_to = try graph_discovery_scan.scanModuleRangeSequential(self, io, 0, 1);
        const pending_after_entry = self.modules.count() - spawned_up_to;
        if (pending_after_entry > 0 and pending_after_entry <= 16) {
            spawned_up_to = try graph_discovery_scan.scanModuleRangeSequential(self, io, spawned_up_to, self.modules.count());
        }
    }

    if (spawned_up_to < self.modules.count()) {
        // 0.16: std.Thread.Pool 제거 → std.Io.Group. 동시성은 io 의 async_limit 가
        // 결정(--jobs→async_limit; single 이면 io.async 가 inline 실행 = 순차). work-stealing
        // (recv 후 신규 모듈 즉시 dispatch) 패턴은 그대로. group.async 는 실패하지 않으므로
        // pool_ok fallback 불필요.
        var channel = MpscChannel(graph_discovery_scan.ScanResult).init(self.allocator);
        defer channel.deinit();

        var group: std.Io.Group = .init;
        var inflight: usize = 0;

        // Spawn the initial modules: entries, inject files, and run-before-main files.
        while (spawned_up_to < self.modules.count()) : (spawned_up_to += 1) {
            const m = self.modules.at(spawned_up_to);
            if (m.state == .ready) continue; // Skip disabled modules.
            const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
            group.async(io, graph_discovery_scan.scanWorker, .{ self, io, idx, &channel });
            inflight += 1;
        }

        // Apply each worker result, then immediately dispatch newly discovered modules.
        while (inflight > 0) {
            const result = channel.recv(io);
            inflight -= 1;
            try graph_discovery_scan.applyScanResult(self, io, result);

            // Dispatch newly discovered modules without waiting for a batch boundary.
            while (spawned_up_to < self.modules.count()) : (spawned_up_to += 1) {
                const m = self.modules.at(spawned_up_to);
                if (m.state == .ready) continue;
                const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(spawned_up_to)));
                group.async(io, graph_discovery_scan.scanWorker, .{ self, io, idx, &channel });
                inflight += 1;
            }
        }

        // 모든 결과 수신 완료 — worker 함수가 완전히 반환하고 group 리소스 해제될 때까지 대기.
        group.await(io) catch {};
    }

    var runtime_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer runtime_indices.deinit(self.allocator);
    try applyRuntimePolyfills(self, io, &runtime_indices);
    try injectEmittedChunks(self, io);
    try linkExecutionRoots(self, entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);
    discover_scope.end();

    try finalizeGraph(self, entry_points);
}

/// PR7-2b (#1880): plugin `this.emitFile({ type: 'chunk', id })` 로 별도 chunk 요청된 모듈을
/// graph 에 주입/표시한다. discovery 패스가 모두 끝난 뒤(build thread, 모든 hook drain) emit_store
/// .chunks 를 read 하므로 Node main 의 write 와 패스 경계로 분리돼 mutex 불필요(RFC §3 옵션 B).
///
/// **B-i**: id 가 *이미 graph 에 있는* 모듈이면 `is_emitted_chunk_entry` 플래그만 set.
/// **B-ii**: graph 에 없는 신규 모듈이면 `resolve_cache` 로 resolve(상대/bare specifier 도
/// project_root 기준 — RFC §4.2) → `addModuleWithResolveDir`(dedup) → 플래그 + `requestAll` →
/// `discoverPendingModulesSequential`. emit-within-emit 은 fixpoint 루프로 재드레인.
/// finalizeGraph 가 DFS 루트로, chunk.zig 가 dynamic entry 로 분리, tree_shaker 가 entry_set 으로
/// 생존시킨다. 플래그는 renumber 가 Module 을 옮겨도 따라가므로(shallow copy) 이후 단계가 renumber
/// 후 안전하게 읽는다(index 배열 전달 불필요).
fn injectEmittedChunks(self: *ModuleGraph, io: std.Io) !void {
    const store_ptr = self.emit_store orelse return; // chunk 미사용 빌드: hot path 0
    const store: *@import("../emit_store.zig").EmitStore = @ptrCast(@alignCast(store_ptr));
    if (store.chunks.items.len == 0) return;
    // emit chunk 는 별도 chunk 분리가 가능한 모드에서만 의미. 단일파일 모드(splitting:false)면
    // chunk 분리가 없어 is_entry_point=true 가 단일파일 entry 오선택을 일으키므로 거부한다
    // (code-review: silent 오동작 방지).
    const splittable = self.code_splitting or self.preserve_modules;
    if (!splittable) {
        for (store.chunks.items) |chk| {
            self.addDiag(
                .plugin_error,
                .@"error",
                chk.id,
                .{ .start = 0, .end = 0 },
                .resolve,
                "this.emitFile({ type: 'chunk' }) requires code splitting (splitting: true).",
                "Enable code splitting, or emit type:'asset' instead.",
            );
        }
        return;
    }

    // 신규 모듈 resolve 기준 디렉토리: importer 가 없으므로 project_root(없으면 entry_dir).
    // 상대/bare specifier 도 이 기준으로 resolve (RFC §4.2). Rollup 의 importer 미지정 emit 과 동형.
    const source_dir = if (self.project_root.len > 0) self.project_root else self.entry_dir;

    // fixpoint (RFC §4.3): 신규 모듈(B-ii)을 addModule → discovery 하면 그 모듈의 transform 이
    // 또 emit chunk 할 수 있어 store.chunks 가 늘 수 있다. processed 까지 처리 후, discovery 가
    // 새 chunk 요청을 더했으면 while 이 재진입. addModule dedup 으로 bounded.
    // 방어 캡: 신뢰 못 할 plugin 이 패스마다 *새로운 distinct id* 를 emit 하면 store.chunks 가
    // 끝없이 자라 미수렴(무한 import 그래프 동형). 정상 빌드는 절대 도달하지 않는 큰 상수로 hang
    // 대신 진단을 낸다.
    var processed: usize = 0;
    var pass: usize = 0;
    const max_passes: usize = 1 << 16;
    while (processed < store.chunks.items.len) {
        pass += 1;
        if (pass > max_passes) {
            self.addDiag(
                .plugin_error,
                .@"error",
                store.chunks.items[processed].id,
                .{ .start = 0, .end = 0 },
                .resolve,
                "this.emitFile({ type: 'chunk' }) did not converge — a plugin keeps emitting new chunk ids during discovery.",
                "Emit a finite, stable set of chunk ids; avoid emitting a fresh id on every transform.",
            );
            break;
        }
        const cur_len = store.chunks.items.len;
        const before_count = self.modules.count();
        for (store.chunks.items[processed..cur_len]) |chk| {
            if (self.path_to_module.get(chk.id)) |idx| {
                // 이미 graph 에 있는 모듈 (B-i).
                const ei = @intFromEnum(idx);
                if (ei >= self.modules.count()) continue;
                const m = self.modules.at(ei);
                if (m.is_external or m.is_disabled) {
                    self.addDiag(
                        .plugin_error,
                        .@"error",
                        chk.id,
                        .{ .start = 0, .end = 0 },
                        .resolve,
                        "this.emitFile({ type: 'chunk' }) id resolves to an external/disabled module — cannot be a chunk.",
                        "Pass an id of a normal (bundled) module already in the graph.",
                    );
                    continue;
                }
                m.is_emitted_chunk_entry = true;
            } else if (std.fs.path.isAbsolute(chk.id)) {
                // 절대경로면 resolve 불필요 — 그대로 등록한다. 플랫폼 무관(Windows `C:\` 포함)이며
                // resolver 가 abs 를 bare specifier 로 오인하는 경로를 피한다. 존재/disabled/read
                // 실패는 discovery 후 phantom 재스캔이 정리(B-ii 머지본 동작 유지).
                const new_idx = self.addModule(io, chk.id) catch {
                    self.addDiag(
                        .plugin_error,
                        .@"error",
                        chk.id,
                        .{ .start = 0, .end = 0 },
                        .resolve,
                        "this.emitFile({ type: 'chunk' }) id could not be added to the graph.",
                        "Pass an absolute, readable file path or a resolvable specifier.",
                    );
                    continue;
                };
                _ = try graph_requested_exports.requestAll(self, new_idx);
                const nei = @intFromEnum(new_idx);
                if (nei < self.modules.count()) self.modules.at(nei).is_emitted_chunk_entry = true;
            } else {
                // 상대/bare specifier (B-ii): source_dir(project_root) 기준 resolve (RFC §4.2).
                // plugin 이 this.resolve 를 선호출하지 않아도 된다(Rollup 동형).
                const resolved = self.resolve_cache.resolveThreadSafe(source_dir, chk.id, .static_import) catch |err| switch (err) {
                    error.ModuleNotFound => {
                        self.addDiag(
                            .plugin_error,
                            .@"error",
                            chk.id,
                            .{ .start = 0, .end = 0 },
                            .resolve,
                            "this.emitFile({ type: 'chunk' }) id could not be resolved.",
                            "Pass a resolvable specifier (relative to project root) or an id already in the graph.",
                        );
                        continue;
                    },
                    else => |e| return e,
                };
                // null = external(isExternal). external 은 chunk 가 될 수 없다.
                const m_union = resolved orelse {
                    self.addDiag(
                        .plugin_error,
                        .@"error",
                        chk.id,
                        .{ .start = 0, .end = 0 },
                        .resolve,
                        "this.emitFile({ type: 'chunk' }) id resolves to an external module — cannot be a chunk.",
                        "Pass an id of a normal (bundled) module.",
                    );
                    continue;
                };
                switch (m_union) {
                    .file => |f| {
                        // PR resolve interning: f.path / f.resolve_dir 는 path_pool 소유 (borrow only).
                        const new_idx = try self.addModuleWithResolveDir(io, f.path, f.resolve_dir);
                        const nei = @intFromEnum(new_idx);
                        if (nei >= self.modules.count()) continue;
                        const nm = self.modules.at(nei);
                        // 기존 external/disabled 모듈로 dedup 되면 chunk 대상이 아니다. 신규 모듈은
                        // discovery 후 phantom 재스캔이 정리하지만, dedup(count 불변)은 재스캔이
                        // skip 되므로 여기서 가드한다 (B-i 와 대칭, code-review).
                        if (nm.is_external or nm.is_disabled) {
                            self.addDiag(
                                .plugin_error,
                                .@"error",
                                chk.id,
                                .{ .start = 0, .end = 0 },
                                .resolve,
                                "this.emitFile({ type: 'chunk' }) id resolves to an external/disabled module — cannot be a chunk.",
                                "Pass an id of a normal (bundled) module.",
                            );
                            continue;
                        }
                        _ = try graph_requested_exports.requestAll(self, new_idx);
                        nm.is_emitted_chunk_entry = true;
                    },
                    .disabled => |d| {
                        _ = d;
                        self.addDiag(
                            .plugin_error,
                            .@"error",
                            chk.id,
                            .{ .start = 0, .end = 0 },
                            .resolve,
                            "this.emitFile({ type: 'chunk' }) id resolves to a disabled module — cannot be a chunk.",
                            "Pass an id of a normal (bundled) module.",
                        );
                    },
                    // Phase-1 cache 는 virtual/dataurl/external/custom 을 반환하지 않는다
                    // (resolve_imports.zig 와 동일 불변식). 방어적 진단 — crash 대신 surfacing.
                    .virtual, .dataurl, .external, .custom => {
                        self.addDiag(
                            .plugin_error,
                            .@"error",
                            chk.id,
                            .{ .start = 0, .end = 0 },
                            .resolve,
                            "this.emitFile({ type: 'chunk' }) id resolves to a non-file module — unsupported as a chunk.",
                            "Pass an id of a normal (bundled) file module.",
                        );
                    },
                }
            }
        }
        processed = cur_len;
        // 새로 추가된 emit chunk 모듈을 parse/resolve. discovery 중 transform 이 또 emit chunk
        // 하면 store.chunks 가 늘어 while 이 재진입(fixpoint).
        if (self.modules.count() > before_count) {
            try discoverPendingModulesSequential(self, io, before_count);
            // discovery 가 신규 모듈을 external/disabled 로 판정했거나 read 실패(source 비어)면
            // chunk 대상이 아니다 — 플래그를 clear 해 phantom 모듈이 entry/chunk 로 새는 것을
            // 막는다. B-i 는 set 전에 가드하지만 B-ii 는 discovery 전에 set 하므로 사후 재검증
            // (code-review: disabled/ghost 모듈 누수 방지). read 실패는 별도 진단으로 surfacing.
            var ni = before_count;
            while (ni < self.modules.count()) : (ni += 1) {
                const nm = self.modules.at(ni);
                if (!nm.is_emitted_chunk_entry) continue;
                if (nm.is_external or nm.is_disabled or nm.source.len == 0) {
                    nm.is_emitted_chunk_entry = false;
                }
            }
        }
    }

    // implicitlyLoadedAfterOneOf (#3664): 모든 emit chunk 가 graph 에 추가된 *뒤* 양방향 관계를
    // 배선한다. fixpoint 안에서 하면 parent 가 더 나중 패스에 추가되는 emit chunk 일 때 미존재로
    // 오판해 헛 진단이 난다 → 루프 종료 후 일괄 처리(이때 모든 emit chunk 가 path_to_module 에 있음).
    // 인덱스는 이후 finalizeGraph 의 renumber 가 remap 한다(renumber.zig).
    for (store.chunks.items) |chk| {
        if (chk.implicitly_loaded_after_one_of.len == 0) continue;
        const e_idx = resolveExistingModuleIndex(self, source_dir, chk.id) orelse continue;
        try wireImplicitlyLoaded(self, e_idx, chk.implicitly_loaded_after_one_of, source_dir);
    }
}

/// implicitlyLoadedAfterOneOf (#3664, Rollup #3606): emit chunk(e_idx)이 "이들 중 하나가 먼저
/// 로드된 뒤에 로드"된다는 관계를 양방향으로 graph 에 기록한다. E.implicitly_loaded_after_one_of
/// += [parent], parent.implicitly_loaded_before += [E]. getModuleInfo(manualChunks meta)가 보고.
/// **데이터만** — 이 관계를 chunk 중복제거에 반영하는 최적화는 follow-up. 부모 id 는 이미 graph 에
/// 있어야 한다(Rollup 도 "유일 chunk 연결" 요구) → 미존재 시 진단(silent drop 금지).
fn wireImplicitlyLoaded(self: *ModuleGraph, e_idx: ModuleIndex, ids: []const []const u8, source_dir: []const u8) !void {
    if (ids.len == 0) return;
    const ei = @intFromEnum(e_idx);
    if (ei >= self.modules.count()) return;
    for (ids) |raw_id| {
        const parent_idx = resolveExistingModuleIndex(self, source_dir, raw_id) orelse {
            self.addDiag(
                .plugin_error,
                .@"error",
                raw_id,
                .{ .start = 0, .end = 0 },
                .resolve,
                "this.emitFile({ type: 'chunk', implicitlyLoadedAfterOneOf }) id is not in the module graph.",
                "Pass an id reachable from an existing entry (a user entry or a previously emitted chunk).",
            );
            continue;
        };
        if (parent_idx == e_idx) continue; // self-reference 무시
        const pi = @intFromEnum(parent_idx);
        if (pi >= self.modules.count()) continue;
        try appendUniqueModuleIndex(self.allocator, &self.modules.at(ei).implicitly_loaded_after_one_of, parent_idx);
        try appendUniqueModuleIndex(self.allocator, &self.modules.at(pi).implicitly_loaded_before, e_idx);
    }
}

fn appendUniqueModuleIndex(allocator: std.mem.Allocator, list: *std.ArrayList(ModuleIndex), val: ModuleIndex) !void {
    for (list.items) |x| {
        if (x == val) return;
    }
    try list.append(allocator, val);
}

/// id 를 *이미 graph 에 있는* 모듈 index 로 해석한다 (신규 추가 안 함 — implicit 부모는 존재해야).
/// graph 키(abs/이미 등록)면 직접, 상대/bare 면 resolve 후 abs 로 lookup. 미존재면 null.
fn resolveExistingModuleIndex(self: *ModuleGraph, source_dir: []const u8, id: []const u8) ?ModuleIndex {
    if (self.path_to_module.get(id)) |idx| return idx;
    if (std.fs.path.isAbsolute(id)) return null; // abs 는 위에서 이미 시도됨
    const resolved = self.resolve_cache.resolveThreadSafe(source_dir, id, .static_import) catch return null;
    const m_union = resolved orelse return null;
    switch (m_union) {
        .file => |f| {
            // PR resolve interning: f.path 는 path_pool 소유 (borrow only).
            return self.path_to_module.get(f.path);
        },
        .disabled => return null,
        else => return null,
    }
}

fn applyRuntimePolyfills(self: *ModuleGraph, io: std.Io, runtime_indices: *std.ArrayList(ModuleIndex)) !void {
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
        const idx = try self.addModule(io, module.path);
        _ = try graph_requested_exports.requestAll(self, idx);
        if (self.moduleAtMut(idx)) |m| {
            m.is_context_dep = true;
        }
        try runtime_indices.append(self.allocator, idx);
        try self.runtime_polyfill_roots.append(self.allocator, module.path);
        graph_runtime_polyfills.logPrelude(plan, module);
    }
    try discoverPendingModulesSequential(self, io, discover_start);
}

fn discoverPendingModulesSequential(self: *ModuleGraph, io: std.Io, start_index: usize) !void {
    var parse_start = start_index;
    while (parse_start < self.modules.count()) {
        const parse_end = self.modules.count();
        for (parse_start..parse_end) |j| {
            const m = self.modules.at(j);
            if (m.state == .ready) continue;
            self.parseModule(io, @enumFromInt(@as(u32, @intCast(j))));
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

    // discovery 워커 race 로 비결정인 module_index 를 BFS 순으로 재부여.
    // linker init 전에 수행해 외부 idx 키 자료구조 영향 0.
    try renumber.renumberModulesDeterministically(self, entry_points);

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

    // PR7-2b-i (#1880): emit chunk 모듈도 DFS 루트 — exec_index 부여 + is_entry_point(export 보존).
    // renumber 후라 플래그를 순회해 현재 index 로 처리(plugin emit 은 entry_points 경로에 없음).
    // 이미 import 된 모듈(B-i)이면 dfs 가 visited 로 빠르게 리턴, is_entry_point/markViaDynamic 만 의미.
    {
        var mi: usize = 0;
        while (mi < self.modules.count()) : (mi += 1) {
            const m = self.modules.at(mi);
            if (!m.is_emitted_chunk_entry) continue;
            m.is_entry_point = true;
            const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(mi)));
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
    io: std.Io,
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

    // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용).
    // 매 buildIncremental 시 entry_points 로부터 재계산 — watch 모드에서 entry
    // 추가/삭제 시 stale 회피 (Issue #65). computeEntryDir 는 O(N) pure fn.
    // project_root 는 user-set 옵션 (RN/Metro `projectRoot`) 보존을 위해 강제
    // invalidate 하지 않는다 — 자동 추론은 *최초* 빈 값일 때만.
    if (entry_points.len > 0) {
        self.entry_dir = computeEntryDir(entry_points);
    }
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, io, self.entry_dir) catch self.entry_dir;
    }

    // --inject 파일을 먼저 모듈 그래프에 추가
    var inject_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer inject_indices.deinit(self.allocator);
    for (self.inject_files) |inject_path| {
        const idx = try self.addModule(io, inject_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try inject_indices.append(self.allocator, idx);
    }

    var run_before_main_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer run_before_main_indices.deinit(self.allocator);
    for (self.run_before_main_files) |rbm_path| {
        const idx = try self.addModule(io, rbm_path);
        _ = try graph_requested_exports.requestAll(self, idx);
        try run_before_main_indices.append(self.allocator, idx);
    }

    for (entry_points) |entry_path| {
        const idx = try self.addModule(io, entry_path);
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
                var s_mtime = profile.begin(.graph_discover_incr_mtime);
                defer s_mtime.end();
                if (changed_files) |cf| {
                    if (!cf.contains(mod_path)) {
                        if (store.modules.get(mod_path)) |cached_entry| {
                            break :blk cached_entry.mtime;
                        }
                    }
                }
                break :blk getMtime(io, mod_path) catch 0;
            };

            // 캐시 조회. `defer` 가 아닌 명시 `end()` — getIfFresh 호출 자체만 측정해야
            // 하고, 뒤따르는 if/else 분기(cache_hit_assign / miss_parse) 시간이 섞이면
            // 안 된다. 이 분기들은 각자 자기 scope 로 따로 측정한다.
            var s_cl = profile.begin(.graph_discover_incr_cache_lookup);
            const lookup_result = store.getIfFresh(mod_path, mtime);
            s_cl.end();
            if (lookup_result) |cached| {
                var s_ha = profile.begin(.graph_discover_incr_cache_hit_assign);
                defer s_ha.end();
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
                // is_emitted_chunk_entry 는 빌드별 derived state(plugin this.emitFile chunk).
                // store round-trip 으로 복원하면 이전 빌드의 emit 이 영구 split 으로 굳으므로
                // 매 rebuild reset → injectEmittedChunks 가 이번 emit_store.chunks 기준 재set
                // (code-review: watch stale 플래그 방지, #1880 PR7-2b-i).
                mod.is_emitted_chunk_entry = false;
                // PR-Z3: 정상 경로에선 `addModuleWithResolveDir` 에서 이미 capacity 8 을
                // 확보하므로 여기서는 no-op (saved_deps 는 그 capacity 를 그대로 캐리).
                // 다만 disabled/external 같은 by-pass 경로가 미래에 cache-hit 분기로
                // 흘러들어올 가능성에 대한 방어선이고, 이미 8 이상이면 비교 1번뿐이라
                // 코스트는 무시 가능. (M8 측정 record_dep link 88%).
                mod.dependencies.ensureTotalCapacity(self.allocator, 8) catch {};
                mod.importers.ensureTotalCapacity(self.allocator, 8) catch {};
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
                // export_index_by_name (PR-Y1) 도 동일 ownership 이전 패턴 — graph deinit
                // 만 free, 다음 rebuild 의 populate 가 cached.module 의 export_bindings 로
                // 재build. cached.module 쪽 stale 포인터 회피.
                cached.module.export_index_by_name = null;
                // PR #3738: namespace_access_index 도 동일 — parse_arena 안 HashMap backing 이라
                // arena 양도 시 graph 쪽이 (arena, index) 짝 소유. store 쪽 dangling 방지.
                cached.module.namespace_access_index = null;
                // RFC #3940 Sub-PR-L.5c — rename 은 build-scope `Linker.rename_table` 에만 살고
                // graph-scope Symbol 은 더 이상 rename 포인터를 보유하지 않는다. cross-build
                // stale 가 구조적으로 불가능해 별도 reset 이 필요 없다.
                mod.state = .ready;
            } else {
                var s_mp = profile.begin(.graph_discover_incr_miss_parse);
                defer s_mp.end();
                // 캐시 미스: 정상 파싱
                self.parseModule(io, @enumFromInt(@as(u32, @intCast(i))));
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
                var s_rp = profile.begin(.graph_discover_incr_replay);
                defer s_rp.end();
                try graph_resolve_imports.replayCachedResolvedDeps(self, i);
                try graph_resolve_imports.resolveDeferredRequestedImportsIfReady(self, ModuleIndex.fromUsize(i));
            } else {
                var s_mr = profile.begin(.graph_discover_incr_miss_resolve);
                defer s_mr.end();
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
    try applyRuntimePolyfills(self, io, &runtime_indices);
    if (self.modules.count() > before_runtime_count) graph_changed = true;
    // watch/incremental 에서도 emit chunk 플래그를 이번 emit_store.chunks 기준으로 set
    // (cache-hit restore 에서 stale 은 이미 reset). build() 와 동일 처리 (#1880 PR7-2b-i).
    // 신규 emit chunk 모듈(B-ii)은 메인 discovery 루프 밖(injectEmittedChunks 안)에서 추가/파싱
    // 되므로 reparsed 에 누락된다 → 그 모듈 경로를 모아 renumber 후 reparsed 에 등록한다(아래).
    // 누락 시 HMR diff 가 그 모듈 코드를 "no change" 로 drop → client 에 안 실려 stale (#3664).
    const before_emit_count = self.modules.count();
    try injectEmittedChunks(self, io);
    var emit_new_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer emit_new_paths.deinit(self.allocator);
    if (self.modules.count() > before_emit_count) {
        graph_changed = true; // 신규 emit chunk 모듈 추가 = 그래프 변경(rebuild 가 no-change 로 처리되지 않게).
        var ni = before_emit_count;
        while (ni < self.modules.count()) : (ni += 1) {
            const m = self.modules.at(ni);
            // phantom 재스캔 기준(external/disabled/empty-source)과 동일하게 거른다 — read 실패로
            // 비워진 모듈은 emit 할 코드가 없어 reparsed 에 넣어봐야 dev_code 매칭이 안 된다.
            if (m.state != .ready or m.is_external or m.is_disabled or m.source.len == 0) continue;
            // path 슬라이스는 arena 소유라 renumber(모듈 struct 재배치)에도 안정 → 후속 lookup 키.
            // emit chunk entry 뿐 아니라 그 신규 transitive dep 도 번들에 처음 등장 → 모두 re-emit 대상.
            try emit_new_paths.append(self.allocator, m.path);
        }
    }
    // 한계(orthogonal, 미해결): emit 하는 transform 이 cache-hit 으로 skip 되면 emit_store.chunks 가
    // 비어 그 chunk 가 재플래그 안 돼 main 으로 합쳐진다(emit-on-transform + 증분캐시 모델 속성).
    // 이 fix 는 "신규 emit chunk 모듈이 reparsed 누락" 만 해결 — cache-hit-collapse 는 별도 follow-up.
    try linkExecutionRoots(self, entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);

    discover_scope.end();

    try finalizeGraph(self, entry_points);

    // renumber(finalizeGraph 내부) 가 path_to_module 을 post-renumber 인덱스로 갱신하므로, 신규
    // emit chunk 모듈을 *여기서* path→인덱스로 조회해 reparsed 에 넣는다(pre-renumber 인덱스를
    // 넣으면 emit 모듈은 orphan 으로 끝으로 재배치돼 stale). 메인 루프 reparsed 는 reachable 모듈
    // 이라 orphan 추가에 인덱스가 흔들리지 않아 그대로 유효.
    for (emit_new_paths.items) |p| {
        if (self.path_to_module.get(p)) |idx| try reparsed.append(self.allocator, idx);
    }

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
pub fn getMtime(io: std.Io, path: []const u8) !i128 {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (path.len >= std.fs.max_path_bytes) return error.NameTooLong;
    const stat = try fs.statFile(io, path);
    return stat.mtime;
}

/// 증분 빌드 teardown: `graph.deinit()` 직전에 모든 모듈을 persistent
/// store 로 이전한다. `putModule` 이 `parse_arena` 소유권을 store 로
/// 가져가므로 이후 `graph.deinit()` 에서 이중 해제가 발생하지 않는다.
///
/// store transfer 는 `parse_arena` 소유권 이동이라 `*Module` mutable 이
/// 필요하다. graph 내부 전용 `moduleAtMut` 호출을 이 graph 메서드 안으로
/// 가두어, bundler 등 외부 호출자가 raw `moduleAtMut` 를 직접 잡지 않게
/// 한다 (phase accessor 불변식 — graph.zig accessor 주석 참조).
pub fn transferModulesToStore(self: *ModuleGraph, io: std.Io, store: *module_store.PersistentModuleStore) void {
    for (0..self.moduleCount()) |i| {
        const m = self.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
        if (m.parse_arena == null) continue; // disabled 등 arena 없는 모듈 스킵
        // mtime 은 buildIncremental / build 가 이미 module.mtime 에 기록.
        // 여기서 재-stat 하면 watcher-driven mtime cache 효과가 half-revert
        // 됨 (Issue #1727 §3). 0 이면 초기 경로에서 실패했던 모듈 —
        // fallback 으로 한 번 더 stat.
        const mtime = if (m.mtime != 0) m.mtime else (getMtime(io, m.path) catch 0);
        store.putModule(m.path, m, mtime);
    }
}

inline fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// 두 절대/상대 path 의 공통 prefix 를 segment 경계에서 잘라 반환.
///
/// `entry_dir` 계산용 헬퍼 — esbuild `outbase` 자동 추론과 동치.
/// - mid-segment cut 회피(예: `/x/def-a` vs `/x/def-b` → `/x/def-` 가 아닌 `/x`).
/// - 한쪽이 다른 쪽의 정확한 dir prefix 면 그쪽 반환(`/x/y` vs `/x/y/z` → `/x/y`).
/// - 절대 경로가 root `/` 만 공유하면 root sep 보존(`/a` vs `/b` → `/`) —
///   F1 가드(없으면 절대 entry sibling 들이 entry_dir="" 폴백돼 [dir] 토큰 무효화).
fn commonPathPrefix(a: []const u8, b: []const u8) []const u8 {
    var i: usize = 0;
    const min_len = @min(a.len, b.len);
    while (i < min_len and a[i] == b[i]) : (i += 1) {}
    if (i == a.len and i == b.len) return a;
    if (i == a.len and i < b.len and isPathSep(b[i])) return a;
    if (i == b.len and i < a.len and isPathSep(a[i])) return b;
    // i 까지 본 byte 중 마지막 separator 직전까지 잘라 segment 경계 보장.
    // separator 가 첫 byte(root sep) 라면 root prefix `/` 를 유지.
    var cut: usize = 0;
    var has_root_sep = false;
    var j: usize = 0;
    while (j < i) : (j += 1) {
        if (isPathSep(a[j])) {
            if (j == 0) has_root_sep = true else cut = j;
        }
    }
    if (cut == 0 and has_root_sep) return a[0..1];
    return a[0..cut];
}

/// entry_points 의 dirname 들의 longest common parent 를 반환.
/// 모든 entry 의 dirname 을 segment 경계에서 교집합 — esbuild `outbase` 동치.
/// 빈 slice 반환 = 공통 부모 없음 → 평면 emit fallback.
fn computeEntryDir(entry_points: []const []const u8) []const u8 {
    if (entry_points.len == 0) return "";
    var common: []const u8 = std.fs.path.dirname(entry_points[0]) orelse "";
    var i: usize = 1;
    while (i < entry_points.len) : (i += 1) {
        const dir = std.fs.path.dirname(entry_points[i]) orelse "";
        common = commonPathPrefix(common, dir);
        if (common.len == 0) break;
    }
    return common;
}

test "commonPathPrefix — sibling dirs cut at segment boundary" {
    const r = commonPathPrefix("/tmp/x/def-a", "/tmp/x/def-b");
    try std.testing.expectEqualStrings("/tmp/x", r);
}

test "commonPathPrefix — exact prefix returns shorter" {
    try std.testing.expectEqualStrings("/x/y", commonPathPrefix("/x/y", "/x/y/z"));
    try std.testing.expectEqualStrings("/x/y", commonPathPrefix("/x/y/z", "/x/y"));
}

test "commonPathPrefix — identical paths" {
    try std.testing.expectEqualStrings("/a/b/c", commonPathPrefix("/a/b/c", "/a/b/c"));
}

test "commonPathPrefix — disjoint absolute paths share root sep" {
    // F1 가드: 둘 다 root-anchored 이면 root `/` 공유. esbuild parity.
    try std.testing.expectEqualStrings("/", commonPathPrefix("/a/b", "/c/d"));
}

test "commonPathPrefix — disjoint relative paths return empty" {
    // root sep 없는 경우엔 빈 결과 — 평면 fallback.
    try std.testing.expectEqualStrings("", commonPathPrefix("a/b", "c/d"));
}

test "commonPathPrefix — root-only siblings keep root sep (F1)" {
    try std.testing.expectEqualStrings("/", commonPathPrefix("/a", "/b"));
}

test "commonPathPrefix — Windows-style separators" {
    const r = commonPathPrefix("C:\\repo\\a", "C:\\repo\\b");
    try std.testing.expectEqualStrings("C:\\repo", r);
}

test "computeEntryDir — single entry returns its dirname" {
    const entries = [_][]const u8{"/tmp/x/def-a/index.ts"};
    try std.testing.expectEqualStrings("/tmp/x/def-a", computeEntryDir(&entries));
}

test "computeEntryDir — two sibling entries returns common parent" {
    const entries = [_][]const u8{
        "/tmp/x/def-a/index.ts",
        "/tmp/x/def-b/index.ts",
    };
    try std.testing.expectEqualStrings("/tmp/x", computeEntryDir(&entries));
}

test "computeEntryDir — disjoint absolute entries share root" {
    // F1: 둘 다 root-anchored 라 root `/` 가 entry_dir. esbuild parity.
    const entries = [_][]const u8{
        "/foo/a/index.ts",
        "/bar/b/index.ts",
    };
    try std.testing.expectEqualStrings("/", computeEntryDir(&entries));
}

test "computeEntryDir — relative entries with no common dir return empty" {
    const entries = [_][]const u8{
        "src/a/x.ts",
        "lib/b/y.ts",
    };
    try std.testing.expectEqualStrings("", computeEntryDir(&entries));
}

test "computeEntryDir — empty input returns empty" {
    const entries = [_][]const u8{};
    try std.testing.expectEqualStrings("", computeEntryDir(&entries));
}

test "computeEntryDir — nested + sibling combination" {
    // entries: /repo/src/a/x.ts, /repo/src/b/y/z.ts → common = /repo/src
    const entries = [_][]const u8{
        "/repo/src/a/x.ts",
        "/repo/src/b/y/z.ts",
    };
    try std.testing.expectEqualStrings("/repo/src", computeEntryDir(&entries));
}

// F4 (Issue #65) 회귀 가드: buildIncremental 시 entry_points 가 변경되면
// entry_dir 도 재계산되어야 한다. 옛 코드는 `entry_dir.len == 0` 가드로
// 첫 build 후 영구 보존 → watch 모드에서 entry 추가/삭제 시 stale.
test "F4 watch: entry_points 변경 시 entry_dir 재계산 (자동 추론 모드)" {
    // 시뮬레이션: 첫 entries → 둘째 entries 로 변경. computeEntryDir 자체는
    // pure fn 이라 그 결과를 비교해 *변경 감지 후 재계산* 한다는 invariant 만 검증.
    const first_entries = [_][]const u8{
        "/repo/src/a/index.ts",
        "/repo/src/b/index.ts",
    };
    const first_dir = computeEntryDir(&first_entries);
    try std.testing.expectEqualStrings("/repo/src", first_dir);

    // entry 가 더 추가됨 (다른 sibling) — common parent 그대로
    const expanded_entries = [_][]const u8{
        "/repo/src/a/index.ts",
        "/repo/src/b/index.ts",
        "/repo/src/c/index.ts",
    };
    try std.testing.expectEqualStrings("/repo/src", computeEntryDir(&expanded_entries));

    // entry 가 *완전히 다른* dir 로 추가 — common parent 가 위로 올라감
    const cross_entries = [_][]const u8{
        "/repo/src/a/index.ts",
        "/repo/lib/util.ts",
    };
    try std.testing.expectEqualStrings("/repo", computeEntryDir(&cross_entries));
    // 옛 코드는 self.entry_dir = "/repo/src" 보존했지만 정답은 "/repo"
    // → buildIncremental 의 guard 가 새 결과로 갱신해야.
}

test "F4 watch: entry 가 한 개로 축소되면 entry_dir 가 그 dirname 으로 축소" {
    const initial_entries = [_][]const u8{
        "/repo/src/a/index.ts",
        "/repo/src/b/index.ts",
    };
    try std.testing.expectEqualStrings("/repo/src", computeEntryDir(&initial_entries));

    const single_entry = [_][]const u8{"/repo/src/a/index.ts"};
    try std.testing.expectEqualStrings("/repo/src/a", computeEntryDir(&single_entry));
}
