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
const util = @import("../../util/mod.zig");
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
    // common parent. 0.16: entry_dir 을 graph-owned 로 dupe (caller entry_points
    // 수명에 독립 — dangling 방지). 자동 추론 project_root 는 entry_dir 재설정 시 무효화.
    if (entry_points.len > 0) {
        const ed = computeEntryDir(entry_points);
        if (self.entry_dir.len > 0) self.allocator.free(self.entry_dir);
        self.entry_dir = if (ed.len == 0) "" else (self.allocator.dupe(u8, ed) catch "");
        if (self.project_root_auto) {
            self.project_root = "";
            self.project_root_auto = false;
        }
    }
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, io, self.entry_dir) catch self.entry_dir;
        self.project_root_auto = true;
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
        // 결정(async_limit=0 이면 io.async 가 inline 실행 = 순차). work-stealing
        // (recv 후 신규 모듈 즉시 dispatch) 패턴은 그대로. group.async 는 실패하지 않으므로
        // pool_ok fallback 불필요.
        // --jobs(self.max_threads)는 진입점(CLI main / NAPI common.setJobs)에서 io 의
        // async_limit 으로 반영된다(#4004, bundler.asyncLimitForJobs). --jobs=1 → .nothing
        // 이면 아래 group.async 가 inline 실행 = 순차(디버깅/재현). 출력은 renumber/path-sort
        // (#3564)로 worker 수와 무관하게 byte-identical → async_limit 변화에도 determinism 불변.
        var channel = MpscChannel(graph_discovery_scan.ScanResult).init(self.allocator);
        defer channel.deinit();

        var group: std.Io.Group = .init;
        // #4009: discovery 가 어떤 경로로 빠져나가도(정상 / recv 의 error.SendFailed /
        // applyScanResult error) 워커를 먼저 reap 한 뒤 channel.deinit(아래 defer, LIFO 로
        // 이 await 뒤에 실행)되도록 defer await. recv 가 OOM 시 error 를 던질 때 워커가 떠도는
        // 채 채널이 teardown 되는 UAF + 기존 `try applyScanResult` 에러 경로의 await 누락을 함께
        // 막는다(정상 경로의 명시 await 를 이 defer 로 대체).
        // (알려진 한계: 에러-abort 시 미소비 ScanResult 의 resolve_outputs 는 해제 안 됨 —
        // (a) 워커가 await 직전 send 한 채널 큐 잔류분(channel.deinit 가 item-단위로 못 풂),
        // (b) recvBatch 로 drain 됐으나 applyScanResult 중간 에러로 적용 못 한 batch 잔류분
        //     (batch.deinit 도 backing 만 풀고 item 은 안 풂). 둘 다 같은 클래스이며 총량은
        //     batch 화 전후로 비슷하다(미소비분이 큐↔batch 로 갈릴 뿐). 이미 빌드를 접는 rare
        //     OOM/에러 경로라 수용 — leak-clean 종료가 필요하면 별도 drain follow-up.)
        defer group.await(io) catch {};
        var inflight: usize = 0;

        // #4007: 모듈당 group.async 는 0.16 std.Io.Group 의 per-task dispatch 비용(태스크당
        // 힙alloc + 전역 t.mutex lock + condSignal)을 모듈 수만큼 치러 다모듈 그래프에서 wall
        // 회귀(0.15 Thread.Pool 대비, synthreal 500모듈 +8.6% 실측)를 만든다. pending 비-ready
        // 모듈을 ~parallelism*4 청크의 range-task 로 묶어 dispatch 횟수를 N→~chunks 로 줄여
        // amortize 한다. work-stealing(recv 후 신규 모듈 즉시 dispatch)은 청크 단위로 유지.
        const parallelism: usize = if (self.max_threads != 0) self.max_threads else (std.Thread.getCpuCount() catch 8);

        // 초기 알려진 모듈(entries/inject/run-before-main) 청크 dispatch.
        dispatchPendingChunked(self, io, &group, &channel, &spawned_up_to, &inflight, parallelism);

        // #4003 회귀 fix: 한 번에 쌓인 결과를 *모두* drain 한 뒤 한 번만 dispatch 한다.
        // 이전엔 recv 1개 → 즉시 dispatch 라, fan-out(깊고 좁은) 그래프에서 pending tail 이
        // 모듈당 1~5 → chunkSize=1 → 모듈당 group.async(0.16 per-task 비용)를 그대로 치러
        // bundle 회귀(+29% large)를 만들었다. recvBatch 로 형제 결과를 합류시키면 pending
        // 구간이 커져 dispatchPendingChunked 의 청킹(#4007)이 fan-out 에서도 발동한다.
        var batch: std.ArrayListUnmanaged(graph_discovery_scan.ScanResult) = .empty;
        defer batch.deinit(self.allocator);
        while (inflight > 0) {
            // #4009: 워커 send 가 OOM 으로 결과를 drop 하면 error.SendFailed — 무한 대기 대신
            // 빌드를 실패시킨다(상단 defer group.await 가 워커 reap 보장). recvBatch 는 큐에
            // 쌓인 결과 전체를 한 lock 으로 batch 로 옮긴다(최소 1개 대기).
            // recvBatch 는 큐에 쌓인 결과 전체를 한 lock 으로 batch 로 옮긴다(최소 1개 대기,
            // 내부에서 batch 를 clear 후 swap 하므로 별도 clear 불필요). n = 가져온 결과 수.
            // 워커는 모듈당 결과 1개 send(discovery_scan.scanRangeWorker) → inflight(dispatch
            // 시 per-module 누적)와 단위 일치 → `inflight -= n` 회계 불변.
            const n = try channel.recvBatch(io, &batch);
            inflight -= n;
            // 적용 순서는 비보장이나 determinism 은 renumber(#3564)라 무관(applyScanResult 는
            // result.module_idx 로 적용 → 순서 독립, 기존 swapRemove 경로도 비-FIFO 였음).
            for (batch.items) |result| {
                try graph_discovery_scan.applyScanResult(self, io, result);
            }
            dispatchPendingChunked(self, io, &group, &channel, &spawned_up_to, &inflight, parallelism);
        }
        // (정상 종료 시 group reap 은 상단 `defer group.await` 가 처리)
    }

    // PR-3a: BFS 가 동적 import 경계에서 정지하며 모은 seed 를 일괄 materialize.
    // static 도달 여부가 확정된 시점(워커 reap 후, 단일스레드)이라 안전.
    try materializeLazySeeds(self, io);

    var runtime_indices: std.ArrayList(types.ModuleIndex) = .empty;
    defer runtime_indices.deinit(self.allocator);
    try applyRuntimePolyfills(self, io, &runtime_indices);
    try injectEmittedChunks(self, io);
    try linkExecutionRoots(self, entry_points, inject_indices.items, runtime_indices.items, run_before_main_indices.items);
    discover_scope.end();

    try finalizeGraph(self, entry_points);
}

/// 현재 pending(=spawned_up_to..modules.count()) 비-ready 모듈을 ~parallelism*4 청크의
/// range-task 로 묶어 group.async dispatch 한다(#4007 — 0.16 Io.Group per-task dispatch
/// 비용 amortize). disabled(.ready) 모듈은 메인 스레드가 단일스레드로 건너뛰며 *연속 비-ready
/// 구간* 만 워커에 넘긴다 → scanRangeWorker 가 .state 를 안 읽어 applyScanResult(메인) 와 race
/// 없음(#1779 worker race-safety 불변식 유지). inflight 는 per-module 누적(워커가 모듈당 결과
/// 개별 send) → recv/applyScanResult 회계 불변. determinism(#3564)은 dispatch 단위와 무관.
fn dispatchPendingChunked(
    self: *ModuleGraph,
    io: std.Io,
    group: *std.Io.Group,
    channel: *MpscChannel(graph_discovery_scan.ScanResult),
    spawned_up_to: *usize,
    inflight: *usize,
    parallelism: usize,
) void {
    const count = self.modules.count();
    while (spawned_up_to.* < count) {
        // disabled(.ready) 모듈 스킵 — 메인 스레드 단독 .state 읽기.
        if (self.modules.at(spawned_up_to.*).state == .ready) {
            spawned_up_to.* += 1;
            continue;
        }
        // 연속 비-ready 구간 [lo, hi).
        const lo = spawned_up_to.*;
        var hi = lo + 1;
        while (hi < count and self.modules.at(hi).state != .ready) hi += 1;
        // ~parallelism*4 청크로 분할 (dispatch amortize ↔ load-balance 균형).
        const chunk = util.chunkSize(hi - lo, parallelism);
        var s = lo;
        while (s < hi) {
            const e = @min(s + chunk, hi);
            group.async(io, graph_discovery_scan.scanRangeWorker, .{ self, io, s, e, channel });
            inflight.* += (e - s);
            s = e;
        }
        spawned_up_to.* = hi;
    }
}

/// PR-3a (lazy compilation): discovery 가 동적 import 경계에서 모은 미파싱 seed 를
/// BFS 종료 후 일괄 처리한다. `addModuleWithResolveDir` 로 dedup:
///   - static 으로도 도달해 이미 parse(.ready + ast) 된 모듈이면 미파싱 마크 없이 link
///     만 (entry/shared 단방향 참조, RFC §2.1).
///   - 우리가 방금 추가한 신규 경로(.reserved, ast==null)면 미파싱 seed 로 등록
///     (is_lazy_seed, state=.ready 로 dispatch/parse 회피). 첫 GET 시 parse 는 PR-3b.
/// 워커 reap 후 단일스레드 실행이라 race 없음. lazy_compilation=false 면 seed 가 비어
/// no-op → eager 경로 회귀 0.
fn materializeLazySeeds(self: *ModuleGraph, io: std.Io) !void {
    if (self.lazy_seeds.items.len == 0) return;
    for (self.lazy_seeds.items) |seed| {
        const dep_idx = try self.addModuleWithResolveDir(io, seed.path, seed.resolve_dir);
        if (self.moduleAtMut(dep_idx)) |to_mod| {
            // BFS 종료 후이므로 static 도달 모듈은 .ready(파싱 완료), external/disabled 도
            // .ready. 아직 .reserved + ast 없음 + 비-external 이면 이 seed 가 처음 추가한
            // 미파싱 모듈이다(!is_external 은 방어적 — .reserved external 은 없지만 명시).
            if (to_mod.state == .reserved and to_mod.ast == null and !to_mod.is_external) {
                to_mod.is_lazy_seed = true;
                to_mod.state = .ready;
            }
        }
        try self.linkDynamicImport(seed.from, dep_idx);
        // entry 의 `import()` lowering 이 resolved 타겟(→ 동적 청크)을 참조하도록 갱신.
        if (self.moduleAtMut(seed.from)) |from_mod| {
            if (seed.rec_i < from_mod.import_records.len) {
                from_mod.import_records[seed.rec_i].resolved = dep_idx;
                from_mod.import_records[seed.rec_i].is_lazy_resolved = false;
            }
        }
    }
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
                const resolved = self.resolve_cache.resolveThreadSafe(io, source_dir, chk.id, .static_import) catch |err| switch (err) {
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
        const e_idx = resolveExistingModuleIndex(self, io, source_dir, chk.id) orelse continue;
        try wireImplicitlyLoaded(self, io, e_idx, chk.implicitly_loaded_after_one_of, source_dir);
    }
}

/// implicitlyLoadedAfterOneOf (#3664, Rollup #3606): emit chunk(e_idx)이 "이들 중 하나가 먼저
/// 로드된 뒤에 로드"된다는 관계를 양방향으로 graph 에 기록한다. E.implicitly_loaded_after_one_of
/// += [parent], parent.implicitly_loaded_before += [E]. getModuleInfo(manualChunks meta)가 보고.
/// **데이터만** — 이 관계를 chunk 중복제거에 반영하는 최적화는 follow-up. 부모 id 는 이미 graph 에
/// 있어야 한다(Rollup 도 "유일 chunk 연결" 요구) → 미존재 시 진단(silent drop 금지).
fn wireImplicitlyLoaded(self: *ModuleGraph, io: std.Io, e_idx: ModuleIndex, ids: []const []const u8, source_dir: []const u8) !void {
    if (ids.len == 0) return;
    const ei = @intFromEnum(e_idx);
    if (ei >= self.modules.count()) return;
    for (ids) |raw_id| {
        const parent_idx = resolveExistingModuleIndex(self, io, source_dir, raw_id) orelse {
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
fn resolveExistingModuleIndex(self: *ModuleGraph, io: std.Io, source_dir: []const u8, id: []const u8) ?ModuleIndex {
    if (self.path_to_module.get(id)) |idx| return idx;
    if (std.fs.path.isAbsolute(id)) return null; // abs 는 위에서 이미 시도됨
    const resolved = self.resolve_cache.resolveThreadSafe(io, source_dir, id, .static_import) catch return null;
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);

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
            self.applySideEffectsFromPackageJson(io, m_ptr);
            m_ptr.state = .ready;
        }
        for (parse_start..parse_end) |i| {
            const m_ptr = self.modules.at(i);
            if (m_ptr.is_disabled or m_ptr.is_external) continue;
            try graph_resolve_imports.resolveModuleImports(self, io, @enumFromInt(@as(u32, @intCast(i))));
            try graph_resolve_imports.applyContextDepResults(self, io, i);
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
/// renumber 직후 모든 모듈을 결정적 index 순서로 순회해 `graph.rn_asset_metadata` 를 재구성한다.
/// fresh full 과 preserved(edge-reuse)가 같은 renumber-후 순서로 수집하므로 배열이 byte-identical.
/// 항목 strings 는 각 module 의 parse_arena 소유 — list 는 borrow(여기서 free 하지 않으며,
/// clearRetainingCapacity 로 이전 빌드 항목을 비운다).
fn collectRnAssetMetadata(self: *ModuleGraph) !void {
    self.rn_asset_metadata.clearRetainingCapacity();
    const count = self.modules.count();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const m = self.modules.at(i);
        if (m.rn_asset_metadata) |meta| {
            try self.rn_asset_metadata.append(self.allocator, meta);
        }
    }
}

fn finalizeGraph(self: *ModuleGraph, entry_points: []const []const u8) !void {
    var scope = profile.begin(.graph_finalize);
    defer scope.end();

    // discovery 워커 race 로 비결정인 module_index 를 BFS 순으로 재부여.
    // linker init 전에 수행해 외부 idx 키 자료구조 영향 0.
    try renumber.renumberModulesDeterministically(self, entry_points);

    // renumber 직후 결정적 index 순서로 RN asset metadata 재수집 — fresh full 과 preserved
    // (edge-reuse) 양쪽이 같은 순서로 모아 배열이 byte-identical(항목은 module.parse_arena 소유 borrow).
    try collectRnAssetMetadata(self);

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

// ============================================================
// perf/hmr-graph-topology-reuse Phase A — 위상(topology) 스냅샷 + 가드 primitive
//
// 이 함수들은 "body-only edit(모듈 집합·import 위상 불변)이면 보존, 아니면 full" 판정의
// **corruption-defense 핵심**이다. 변경 모듈을 invalidate(=deinit) *하기 전에* 그 모듈의
// (specifier, kind) 집합 + import_records[].resolved 가 가리키는 타겟 모듈 path 집합을
// 스냅샷한다. import_records 는 parse_arena 소유라 재파싱 시 backing 이 사라지므로 **반드시
// deinit 전에** 떠 둬야 한다(스냅샷은 자체 allocator 로 dupe → arena 수명 독립).
//
// Phase A 에서는 persistent_graph 가 매 빌드 fresh discovery(prepareForPreservedRebuild)라
// 이 primitive 가 *판정 경로에 강제 연결되어 있지는 않다*. 하지만 (1) 단위 테스트로 정확성을
// 못박아 두고 (2) Phase B 의 selective edge-reuse 가 그대로 호출할 가드 표면을 확정한다.
// (Phase B: invalidateModule 전 snapshot → 재파싱 후 topologyMatches → 일치 시 보존, 불일치
// 시 full BFS.)
// ============================================================

/// 한 import record 의 위상 식별자: specifier + kind + (resolve 된) 타겟 모듈 path.
/// resolved_target_path = null 은 "아직 미해석 / external / disabled(specifier 기반)" 를 뜻하며
/// resolve target diff 가드에서 specifier 와 함께 비교된다.
pub const ImportTopologyEntry = struct {
    specifier: []const u8,
    kind: types.ImportKind,
    /// resolve 결과 타겟 모듈의 절대 path (snapshot allocator 소유 — dupe). null = 미해석.
    resolved_target_path: ?[]const u8,
    /// 동적 import 여부(`dynamic_import` kind). dynamic_import diff 가드용 — kind 에 이미
    /// 포함되지만 가드 가독성을 위해 명시 필드로도 노출.
    is_dynamic: bool,
};

/// 변경 모듈의 위상 스냅샷. `entries` 와 각 `specifier`/`resolved_target_path` 문자열은
/// 모두 `allocator` 소유 — `deinit` 으로 일괄 해제. invalidate(deinit) 전에 떠 둬야 한다.
pub const ModuleTopologySnapshot = struct {
    entries: []ImportTopologyEntry,
    /// 변경 모듈이 그 시점에 가졌던 import record 개수(= entries.len). count 비교 fast-path.
    record_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ModuleTopologySnapshot) void {
        for (self.entries) |e| {
            self.allocator.free(e.specifier);
            if (e.resolved_target_path) |p| self.allocator.free(p);
        }
        self.allocator.free(self.entries);
    }
};

/// 변경 모듈(mod_idx)의 import 위상을 스냅샷한다. **invalidateModule 호출 전**에 부른다.
/// specifier/kind 는 import_records(parse_arena 소유)에서, resolved target path 는
/// import_records[].resolved 가 가리키는 모듈의 path(path_arena 소유)에서 떠 dupe 한다.
/// glob/require_context 같은 *동적 확장* record 는 위상 보존 대상이 아니므로(plan §30 잔존
/// 위험) 스냅샷 자체를 거부(null 반환) → caller 가 full 로 폴백.
pub fn snapshotModuleTopology(
    self: *const ModuleGraph,
    allocator: std.mem.Allocator,
    mod_idx: usize,
) !?ModuleTopologySnapshot {
    if (mod_idx >= self.modules.count()) return null;
    const mod = self.modules.at(mod_idx);

    var entries: std.ArrayListUnmanaged(ImportTopologyEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.specifier);
            if (e.resolved_target_path) |p| allocator.free(p);
        }
        entries.deinit(allocator);
    }

    for (mod.import_records) |rec| {
        // glob / require.context 는 build-time FS 확장이라 specifier-set 만으로 위상 불변을
        // 증명할 수 없다 → 보존 거부(보수적 full). (plan §12 제외 빌드와 동형.)
        if (rec.kind == .glob or rec.kind == .require_context) {
            for (entries.items) |e| {
                allocator.free(e.specifier);
                if (e.resolved_target_path) |p| allocator.free(p);
            }
            entries.deinit(allocator);
            return null;
        }
        const spec_copy = try allocator.dupe(u8, rec.specifier);
        var target_path: ?[]const u8 = null;
        errdefer allocator.free(spec_copy);
        if (!rec.resolved.isNone()) {
            const ti = rec.resolved.toUsize();
            if (ti < self.modules.count()) {
                target_path = try allocator.dupe(u8, self.modules.at(ti).path);
            }
        }
        try entries.append(allocator, .{
            .specifier = spec_copy,
            .kind = rec.kind,
            .resolved_target_path = target_path,
            .is_dynamic = rec.kind == .dynamic_import,
        });
    }

    return ModuleTopologySnapshot{
        .entries = try entries.toOwnedSlice(allocator),
        .record_count = mod.import_records.len,
        .allocator = allocator,
    };
}

/// 재파싱 후의 모듈 위상이 `old` 스냅샷과 **위상 동일**한지 판정. 동일 = body-only edit
/// (보존 가능). 다음 중 하나라도 다르면 false(=full 폴백):
///   - import record 개수 변화
///   - specifier 변화 (추가/삭제/수정) — 순서 포함 엄격 비교(parser 가 source 순서 보존)
///   - kind 변화 (static ↔ dynamic ↔ require ↔ re_export 등)
///   - resolve target path 변화 (같은 specifier 가 다른 파일로 해석 — resolve-diff)
///   - dynamic_import diff
///
/// glob/require_context 가 새로 등장하면 new 쪽 record 의 kind 비교에서 자동으로 불일치.
pub fn topologyMatches(old: *const ModuleTopologySnapshot, new_mod: *const ModuleGraph, new_idx: usize) bool {
    if (new_idx >= new_mod.modules.count()) return false;
    const mod = new_mod.modules.at(new_idx);
    if (old.record_count != mod.import_records.len) return false;
    if (old.entries.len != mod.import_records.len) return false;

    for (old.entries, mod.import_records) |oe, rec| {
        if (rec.kind == .glob or rec.kind == .require_context) return false;
        if (oe.kind != rec.kind) return false;
        if (oe.is_dynamic != (rec.kind == .dynamic_import)) return false;
        if (!std.mem.eql(u8, oe.specifier, rec.specifier)) return false;
        // resolve target diff: 새 resolved 타겟 path 를 구해 old 와 비교.
        const new_target: ?[]const u8 = blk: {
            if (rec.resolved.isNone()) break :blk null;
            const ti = rec.resolved.toUsize();
            if (ti >= new_mod.modules.count()) break :blk null;
            break :blk new_mod.modules.at(ti).path;
        };
        const old_target = oe.resolved_target_path;
        if (old_target == null and new_target == null) continue;
        if (old_target == null or new_target == null) return false;
        if (!std.mem.eql(u8, old_target.?, new_target.?)) return false;
    }
    return true;
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
    changed_files: ?*const std.StringHashMapUnmanaged(void),
) !IncrementalBuildResult {
    // #1961: builtin runtime helper plugin prepend (build() 와 동일).
    graph_plugins.ensureBuiltinPlugins(self);

    // entry_dir 계산: entry point들의 공통 부모 디렉토리 ([dir] 패턴용).
    // 매 buildIncremental 시 entry_points 로부터 재계산 — watch 모드에서 entry
    // 추가/삭제 시 stale 회피 (Issue #65). computeEntryDir 는 O(N) pure fn.
    // project_root 는 user-set 옵션 (RN/Metro `projectRoot`) 보존을 위해 강제
    // invalidate 하지 않는다 — 자동 추론은 *최초* 빈 값일 때만.
    // 0.16: entry_dir graph-owned dupe (free previous → 증분 빌드 leak 방지).
    // 자동 추론된 project_root 만 entry_dir 재설정 시 무효화(user-set 은 보존).
    if (entry_points.len > 0) {
        const ed = computeEntryDir(entry_points);
        if (self.entry_dir.len > 0) self.allocator.free(self.entry_dir);
        self.entry_dir = if (ed.len == 0) "" else (self.allocator.dupe(u8, ed) catch "");
        if (self.project_root_auto) {
            self.project_root = "";
            self.project_root_auto = false;
        }
    }
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, io, self.entry_dir) catch self.entry_dir;
        self.project_root_auto = true;
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
    var cache_hit_modules: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer cache_hit_modules.deinit(self.allocator);

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
                try cache_hit_modules.put(self.allocator, @intCast(i), {});
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
                self.applySideEffectsFromPackageJson(io, m_ptr);
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
                try graph_resolve_imports.replayCachedResolvedDeps(self, io, i);
                try graph_resolve_imports.resolveDeferredRequestedImportsIfReady(self, io, ModuleIndex.fromUsize(i));
            } else {
                var s_mr = profile.begin(.graph_discover_incr_miss_resolve);
                defer s_mr.end();
                try graph_resolve_imports.resolveModuleImports(self, io, @enumFromInt(@as(u32, @intCast(i))));
            }
        }

        // 새 모듈이 추가되었으면 그래프 변경
        if (self.modules.count() > parse_end) {
            graph_changed = true;
        }
        parse_start = parse_end;
    }

    // #4071: build() 와 동일하게 동적 import seed 를 materialize 한다. buildIncremental
    // 은 자체 sequential discovery 라 build() 의 `materializeLazySeeds`(위 build_flow:139)
    // 호출을 공유하지 않는다. 그래서 `module_store` 가 주입되는 watch/dev lazy 경로에선
    // 동적 import 의 lazy 게이트(resolve_imports:356)가 seed 만 쌓고 materialize 가 안 돼
    // → 동적 청크가 생성되지 않고 entry 의 `import()` 가 dangling raw 로 남았다(build()
    // 는 `__zntc_load_chunk` 로 정상 재작성). seed 가 신규 모듈(미파싱 lazy seed)을 추가하면
    // graph_changed=true 로 표시해 rebuild 가 no-change 로 오판되지 않게 한다.
    const before_lazy_count = self.modules.count();
    try materializeLazySeeds(self, io);
    if (self.modules.count() > before_lazy_count) graph_changed = true;

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

// ============================================================
// perf/hmr-graph-topology-reuse Phase B — edge-reuse short-circuit (위상 보존 빌드)
//
// **목표**: body-only edit(모듈 집합·import 위상 불변)이면 변경 모듈만 재파싱+재resolve 하고
// 나머지 모듈의 edge/exec_index/resolved_deps/parse_arena 를 **보존**(재discovery/재replay skip).
// graphDiscover 170→~40ms 의 본체. 위상 변화면 full fallback(전량 clear + fresh discovery).
//
// **정확성(byte-identical) 핵심**:
//   1. renumber 미수정 — 위상 불변이면 renumber=identity(SymbolRef 에 박힌 module index 안전).
//      위상 변화는 topologyMatches=false → full fallback(renumber 정상 실행).
//   2. 변경 모듈의 edge(dependencies/importers/dynamic_*) 는 invalidate 전에 스냅샷해 그대로
//      복원 — unlink/relink 하면 dep.importers 내 위치가 바뀌어 출력이 fresh 와 달라진다.
//      재resolve 는 `suppress_edge_link=true` 로 link 단계만 억제하고 import_records[].resolved
//      + resolved_deps 만 새 parse_arena 기준으로 재구성한다(.specifier PathRef UAF 회피 —
//      옛 resolved_deps 를 보존하지 않고 새 arena 로 새로 만든다).
//   3. 위상 일치 = 모듈 추가/삭제 0 → orphan 없음(prune 불필요). 추가/삭제는 변경 모듈의
//      specifier diff 로 topologyMatches=false → full fallback 에서 prepareForPreservedRebuild
//      (전량 clear)가 처리.
//
// **parse_arena 단독 owner**: 보존 모드에선 transferModulesToStore 비활성(bundler.zig) →
// graph 가 parse_arena 를 계속 소유. store 는 비어 cache-hit 경로를 타지 않는다. graph.deinit
// (IncrementalBundler.deinit / RN worker defer)이 parse_arena 를 단독 해제 → double-free 없음.
// ============================================================

/// 위상(topology) 보존 증분 빌드. `preserve_topology=true` 일 때 bundler 가 호출.
///
/// - cold(graph 비어있음) 또는 위상 변화 가드 위반 시 → full discovery(`buildIncremental`).
///   단 보존 모드는 store 를 안 채우므로 store cache-hit 없이 전량 parse(byte-identical full).
/// - warm(graph 보존) + 변경 모듈 전부 body-only(topologyMatches) → 변경 모듈만 재파싱+재resolve,
///   나머지 보존. finalizeGraph(renumber identity + DFS) 후 reparsed=변경 모듈.
pub fn buildIncrementalPreserved(
    self: *ModuleGraph,
    io: std.Io,
    entry_points: []const []const u8,
    store: *module_store.PersistentModuleStore,
    changed_files: ?*const std.StringHashMapUnmanaged(void),
) !IncrementalBuildResult {
    // cold / 첫 빌드 / 직전 fallback 으로 graph 가 비워진 경우 → full discovery.
    // (store 는 보존 모드에서 비어있어 전량 cache-miss = full parse → byte-identical full.)
    if (self.modules.count() == 0) {
        return buildIncremental(self, io, entry_points, store, changed_files);
    }

    // 변경 정보가 없으면(initial-after-warm / CLI) 보존 판정 불가 → full fallback.
    const cf = changed_files orelse return fallbackFullRebuild(self, io, entry_points, store, changed_files);

    // **feature gate** — 보존 경로는 "모듈 집합 전체에서 discovery 중 파생되는 per-build 상태"
    // (worker_entries / rn_asset_metadata / runtime_polyfill_roots / emit chunk / lazy seed 등)를
    // 가진 빌드를 다루지 못한다(변경 모듈만 재resolve 하면 *변경되지 않은* 모듈의 기여분을
    // 재생성/보존할 수 없어 byte-identical 이 깨짐). 이런 빌드는 보수적으로 full fallback.
    // plan §12/§29 의 "plugin/MF/glob/require.context/code_splitting 보존 경로 제외" 와 동형 +
    // RN 의 runtime polyfill / asset 까지 확장. 정확성 우선 — 불확실하면 full.
    if (!canPreserveTopology(self)) {
        return fallbackFullRebuild(self, io, entry_points, store, changed_files);
    }

    // entry_dir/project_root 재계산(buildIncremental 와 동일 — 보존 경로도 entry 변경 반영).
    // entry 변경(추가/삭제)은 아래 "변경 모듈 = 현재 graph 모듈" 가드에서 위상 변화로 잡힌다.
    if (entry_points.len > 0) {
        const ed = computeEntryDir(entry_points);
        if (self.entry_dir.len > 0) self.allocator.free(self.entry_dir);
        self.entry_dir = if (ed.len == 0) "" else (self.allocator.dupe(u8, ed) catch "");
        if (self.project_root_auto) {
            self.project_root = "";
            self.project_root_auto = false;
        }
    }
    if (self.project_root.len == 0 and self.entry_dir.len > 0) {
        self.project_root = graph_project_root.findProjectRoot(self.allocator, io, self.entry_dir) catch self.entry_dir;
        self.project_root_auto = true;
    }
    graph_plugins.ensureBuiltinPlugins(self);

    // 변경 모듈 인덱스 수집 — changed path 가 *현재 graph 에 있는* 모듈이어야 한다.
    // 그래프에 없는 changed path = 신규 파일(모듈 추가 후보) → 위상 변화 → full fallback.
    // entry_points 가 graph 에 없으면(신규 entry) 역시 full fallback.
    var changed_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer changed_indices.deinit(self.allocator);
    {
        var it = cf.iterator();
        while (it.next()) |e| {
            const path = e.key_ptr.*;
            const idx = self.path_to_module.get(path) orelse {
                // changed 파일이 graph 에 없음 → 신규 모듈 추가(위상 변화) 가능성 → full.
                return fallbackFullRebuild(self, io, entry_points, store, changed_files);
            };
            const ui = @intFromEnum(idx);
            if (ui >= self.modules.count()) {
                return fallbackFullRebuild(self, io, entry_points, store, changed_files);
            }
            // **lazy-barrel 가드**: topologyMatches 는 specifier/kind/resolve-target 만 보고
            // *imported 이름 집합* 은 안 본다. resetPerBuildStateForPreserved 가 requested_exports 를
            // 전량 reset 하므로 over-approx(옛 요청 잔존)는 사라졌지만, 보존 경로는 unchanged barrel
            // importer 를 재resolve 하지 않아 그 요청이 *under-approx*(비어 있음) 될 수 있다 — 비-dev
            // 에서 sideEffects:false re-export barrel 의 link 결정(shouldLinkResolvedRecordForModule)
            // 이 fresh 와 달라질 위험. 변경 모듈이 그런 barrel 후보면 보수적 full fallback. 현재
            // canPreserveTopology 의 `!dev_mode` 게이트 + isLazyBarrelCandidate 의 dev=false 로 dev
            // 보존 경로에선 dead 지만, 비-dev 보존이 미래에 켜질 때를 위한 방어로 유지.
            if (graph_requested_exports.isLazyBarrelCandidate(self, self.modules.at(ui))) {
                return fallbackFullRebuild(self, io, entry_points, store, changed_files);
            }
            try changed_indices.append(self.allocator, ui);
        }
    }
    // 모든 entry 가 graph 에 있어야(신규 entry = 위상 변화) 보존 안전.
    for (entry_points) |ep| {
        if (self.path_to_module.get(ep) == null) {
            return fallbackFullRebuild(self, io, entry_points, store, changed_files);
        }
    }
    // 변경 모듈이 없으면(force_dirty 등) 보존된 graph 그대로 finalize — 출력 불변.
    if (changed_indices.items.len == 0) {
        resetPerBuildStateForPreserved(self);
        self.topology_preserved_hits += 1;
        try finalizeGraph(self, entry_points);
        return .{ .graph_changed = false, .reparsed_indices = try self.allocator.alloc(types.ModuleIndex, 0) };
    }

    var discover_scope = profile.begin(.graph_discover);

    // ── 각 변경 모듈: snapshot → edge 보존 invalidate → 재파싱 → 재resolve(link 억제) ──
    // snapshot 들은 모든 변경 모듈 재파싱이 끝난 뒤 일괄 topologyMatches 검사에 쓴다.
    var snapshots: std.ArrayListUnmanaged(ModuleTopologySnapshot) = .empty;
    defer {
        for (snapshots.items) |*s| s.deinit();
        snapshots.deinit(self.allocator);
    }
    // PR-2: usage mode polyfill 이면 변경 모듈의 core-js feature set 을 reparse *전*에 snapshot 해
    // 두고, topologyMatches 통과 후 재수집과 비교한다(아래). 변하면 전역 union 변화 가능 → fallback.
    // entry mode/null plan 은 고정이라 비교 불필요. (changed_indices 와 1:1 정렬.)
    const polyfill_usage_diff = if (self.runtime_polyfills) |p| p.mode == .usage else false;
    var old_usages: std.ArrayListUnmanaged(runtime_polyfills.FeatureSet) = .empty;
    defer {
        for (old_usages.items) |*u| u.deinit(self.allocator);
        old_usages.deinit(self.allocator);
    }

    // 1) 모든 변경 모듈의 위상 스냅샷을 *invalidate/재파싱 전에* 먼저 떠 둔다(import_records 는
    //    parse_arena 소유라 deinit 시 backing 이 사라짐). glob/require_context record 면
    //    snapshot=null → 보존 거부 → full fallback.
    var fallback = false;
    for (changed_indices.items) |ui| {
        const snap_opt = snapshotModuleTopology(self, self.allocator, ui) catch {
            fallback = true;
            break;
        };
        const snap = snap_opt orelse {
            fallback = true;
            break;
        };
        snapshots.append(self.allocator, snap) catch {
            var s = snap;
            s.deinit();
            fallback = true;
            break;
        };
        if (polyfill_usage_diff) {
            var u = runtime_polyfills.collectModuleUsage(self.allocator, self.modules.at(ui)) catch {
                fallback = true;
                break;
            };
            old_usages.append(self.allocator, u) catch {
                u.deinit(self.allocator);
                fallback = true;
                break;
            };
        }
    }
    if (fallback) {
        discover_scope.end();
        return fallbackFullRebuild(self, io, entry_points, store, changed_files);
    }

    // 2) per-build global state reset (diagnostics / source_read_cache / exec·cycle counter).
    //    snapshot 을 뜬 *뒤*, 변경 모듈 재파싱 *전*에 수행한다:
    //    - diagnostics: 이전 빌드의 stale diag 제거(변경 모듈 재파싱이 자기 diag 재생성).
    //    - source_read_cache: 변경 파일의 stale source 캐시 무효화(fresh read 강제).
    //    - exec_counter/cycle_counter: finalizeGraph 의 DFS 가 0 부터 재부여해야 fresh 와 동일.
    //    KEEP: modules/edges/resolved_deps/parse_arena/requested_exports/pkg_info_cache +
    //    runtime_polyfill_roots/run_before_main(보존이 본 PR 의 목적 — PR-2 가 게이트를 풀어 보존
    //    경로로 진입하므로 roots/rbm 을 reset 하면 prelude 가 깨진다). worker_entries 는 게이트가
    //    비어있음을 보장, rn_asset_metadata 는 module-level 재수집(PR-1).
    resetPerBuildStateForPreserved(self);

    // 3) 변경 모듈을 edge 보존하며 재파싱(invalidate). reparseChangedModulePreserveEdges 는
    //    dependencies/importers/dynamic_* 를 떼어 보관 → module.deinit(parse_arena/ast/semantic/
    //    resolved_deps 해제) → 빈 Module init → edge 리스트 복원 → 재파싱.
    for (changed_indices.items) |ui| {
        reparseChangedModulePreserveEdges(self, io, ui);
    }

    // 4) 변경 모듈 재resolve — edge link 억제(보존된 edge 유지), import_records[].resolved +
    //    resolved_deps 만 새 parse_arena 기준으로 재구성. 새 모듈이 추가되면(addModule count
    //    증가) 위상 변화이므로 그 즉시 fallback.
    const count_before_resolve = self.modules.count();
    self.suppress_edge_link = true;
    for (changed_indices.items) |ui| {
        const m = self.modules.at(ui);
        if (m.is_disabled or m.is_external) continue;
        graph_resolve_imports.resolveModuleImports(self, io, ModuleIndex.fromUsize(ui)) catch {
            self.suppress_edge_link = false;
            discover_scope.end();
            return fallbackFullRebuild(self, io, entry_points, store, changed_files);
        };
    }
    self.suppress_edge_link = false;

    // 5) 위상 일치 검사. (a) 모듈이 추가됐거나(count 증가 = 신규 dep) (b) 어느 변경 모듈이라도
    //    snapshot 과 위상 불일치(specifier/kind/resolve-target diff)면 → full fallback.
    if (self.modules.count() != count_before_resolve) {
        discover_scope.end();
        return fallbackFullRebuild(self, io, entry_points, store, changed_files);
    }
    for (changed_indices.items, snapshots.items) |ui, *snap| {
        if (!topologyMatches(snap, self, ui)) {
            discover_scope.end();
            return fallbackFullRebuild(self, io, entry_points, store, changed_files);
        }
    }

    // PR-2 feature-diff: usage mode 에서 변경 모듈의 core-js feature set 이 reparse 전후 다르면
    // 전역 polyfill union 이 바뀔 수 있어(변경 모듈이 유일 변동 항) 보수적 fallback. 같으면 union
    // 불변 → 보존된 runtime_polyfill_roots/polyfill 모듈이 그대로 유효(prelude byte-identical).
    if (polyfill_usage_diff) {
        for (changed_indices.items, old_usages.items) |ui, *old_u| {
            var new_u = runtime_polyfills.collectModuleUsage(self.allocator, self.modules.at(ui)) catch {
                discover_scope.end();
                return fallbackFullRebuild(self, io, entry_points, store, changed_files);
            };
            const same = old_u.eql(&new_u);
            new_u.deinit(self.allocator);
            if (!same) {
                discover_scope.end();
                return fallbackFullRebuild(self, io, entry_points, store, changed_files);
            }
        }
    }

    discover_scope.end();

    // 6) 위상 보존 확정 — renumber(identity) + DFS exec_index 재부여.
    self.topology_preserved_hits += 1;
    try finalizeGraph(self, entry_points);

    // 변경 모듈만 reparsed(HMR diff source-of-truth). renumber 가 module index 를 재배치하므로
    // pre-renumber 인덱스는 stale — changed_files 의 path 로 post-renumber index 를 재조회한다
    // (path slice 는 path_arena 소유라 renumber 후에도 path_to_module 키로 유효).
    var reparsed: std.ArrayListUnmanaged(types.ModuleIndex) = .empty;
    errdefer reparsed.deinit(self.allocator);
    {
        var it = cf.iterator();
        while (it.next()) |e| {
            if (self.path_to_module.get(e.key_ptr.*)) |idx| {
                try reparsed.append(self.allocator, idx);
            }
        }
    }

    return .{
        .graph_changed = false, // 위상 불변 = 그래프 구조 불변
        .reparsed_indices = try reparsed.toOwnedSlice(self.allocator),
    };
}

/// 위상 변화/불확실 시 fail-safe full rebuild.
///
/// **핵심(성능)**: clear 전에 graph 의 현재 모듈을 store 로 이전(transferModulesToStore)한 뒤
/// clear + buildIncremental 한다. 그러면 buildIncremental 이 store cache-hit 으로 변경 안 된
/// 모듈의 재파싱을 skip → fallback 도 *증분*(전량 reparse 가 아님)이다. 보존 모드는 평소
/// transferModulesToStore 를 비활성(graph 단독 owner)하지만, fallback 직전 1회 이전은
/// "graph→store 핸드오프" 로, 직후 buildIncremental 의 cache-hit 이 arena 를 store→graph 로
/// 되돌린다(incremental.zig: cached.module.parse_arena=null). 빌드 끝의 transferModulesToStore
/// 는 보존 모드라 다시 skip → graph 가 단독 owner 로 복귀. double-free 없음(이전 후 graph 쪽
/// parse_arena=null → prepareForPreservedRebuild 의 m.deinit 가 arena no-op).
///
/// 출력은 fresh full 과 byte-identical(store cache-hit 모듈도 fresh 와 동일 — Phase A 검증됨).
fn fallbackFullRebuild(
    self: *ModuleGraph,
    io: std.Io,
    entry_points: []const []const u8,
    store: *module_store.PersistentModuleStore,
    changed_files: ?*const std.StringHashMapUnmanaged(void),
) !IncrementalBuildResult {
    self.topology_fallback_count += 1;
    // graph→store 핸드오프: 현재 모듈의 parse_arena 를 store 로 이전(graph 쪽 parse_arena=null).
    // 이후 buildIncremental 이 store cache-hit 으로 미변경 모듈 reparse 를 skip.
    transferModulesToStore(self, io, store);
    self.prepareForPreservedRebuild();
    return buildIncremental(self, io, entry_points, store, changed_files);
}

/// 위상 보존(edge-reuse) 경로가 안전한 빌드인지 판정. false 면 full fallback.
///
/// 보존 경로는 *변경 모듈만* 재resolve 하므로, "모든 모듈에서 discovery 중 파생되는 per-build
/// 상태"를 가진 빌드는 다루지 못한다 — 변경되지 않은 모듈의 기여분을 재생성할 수 없어
/// byte-identical 이 깨진다. 다음 중 하나라도 활성이면 보수적으로 거부(full):
///   - 사용자 plugin (resolveId/load/transform 비결정 — plan §12 제외)
///   - code_splitting / preserve_modules (per-chunk 처리 — plan §12 제외)
///   - lazy_compilation (동적 import seed materialize)
///   - runtime_polyfills (usage-mode 는 모듈 전체 feature 스캔 — body edit 가 feature 변화 가능)
///   - inject_files / run_before_main_files (execution root 합류 — 변경 모듈만으론 재배선 불가)
///   - MF(emit_store) (federation/emit chunk)
///   - 이미 누적된 per-build 파생물 보유: worker_entries / rn_asset_metadata /
///     runtime_polyfill_roots (변경 모듈만 재resolve 하면 이들의 unchanged 기여분이 보존 안 됨)
///
/// glob/require_context 는 snapshotModuleTopology 가 record 단위로 null 반환 → 거기서 거부.
///
/// **dev_mode 전제**: 보존 경로는 dev/HMR(web IncrementalBundler.enable_persistence, RN watch
/// worker)에서만 켜진다. 비-dev(prod tree-shaking)에선 requested_exports over-approximation
/// (named import 제거 시 옛 요청 잔존)이 tree-shake 결과를 fresh 와 다르게 만들 수 있어 거부한다.
/// dev_mode 는 tree-shaking 비활성(bundler.zig will_tree_shake) + 전 모듈 __esm 래핑이라 그 위험이
/// 없다. lazy-barrel link 결정(requested_exports 의 다른 소비처)은 buildIncrementalPreserved 의
/// 변경-모듈 lazy-barrel 가드가 별도 차단.
fn canPreserveTopology(self: *const ModuleGraph) bool {
    if (!self.dev_mode) return false;
    if (self.has_user_resolve_id_plugins or self.has_user_load_plugins or self.has_transform_plugins) return false;
    if (self.code_splitting or self.preserve_modules) return false;
    if (self.lazy_compilation) return false;
    // (runtime_polyfills 게이트 제거 — PR-2: usage mode 는 buildIncrementalPreserved 의 변경-모듈
    //  feature-diff 가드가 union 변화를 잡아 fallback, entry mode 는 고정이라 무조건 보존.)
    // (run_before_main_files 게이트 제거 — PR-2: 고정 리스트(InitializeCore)라 보존 경로가 edge +
    //  renumber seed 순서를 그대로 유지해 prelude byte-identical. inject_files 는 유지(후속).)
    if (self.inject_files.len > 0) return false;
    if (self.worker_entries.items.len > 0) return false;
    // (rn_asset_metadata 게이트 제거 — PR-1: module.parse_arena 소유 + finalize 재수집.)
    // (runtime_polyfill_roots 게이트 제거 — PR-2: roots/polyfill 모듈 보존(applyRuntimePolyfills
    //  미호출), bundler.zig merge 가 동일 prelude 재생성.)
    // emit_store 에 chunk 요청이 있으면(plugin emitFile chunk) 보존 제외. emit_store 가
    // null 이면 chunk 미사용(hot path 0). 포인터만 검사 — chunk 내용은 injectEmittedChunks 영역.
    if (self.emit_store) |store_ptr| {
        const store: *const @import("../emit_store.zig").EmitStore = @ptrCast(@alignCast(store_ptr));
        if (store.chunks.items.len > 0) return false;
    }
    return true;
}

/// 보존 경로 진입 시 per-build global state 만 reset(modules/edges/resolved_deps/parse_arena/
/// pkg_info_cache 는 보존). `lifecycle.reset()` 의 부분집합:
///   - diagnostics + owned_diagnostic_strings (변경 모듈 재파싱이 자기 diag 재생성)
///   - source_read_cache (변경 파일 fresh read 강제)
///   - exec_counter / cycle_counter (finalizeGraph DFS 가 0 부터 재부여 → fresh 와 동일 exec_index)
///   - requested_exports (아래 UAF 방어로 전량 deinit)
/// **requested_exports 를 반드시 reset(전량 deinit)** 해야 한다 — `RequestedExports.names`(state.zig)
/// 는 `[]const u8` 을 *dupe 없이 borrow* 하며, 그 slice 는 importer 의 `ib.imported_name`/
/// `eb.local_name`(parse_arena 소유, requested_exports.zig requestNamed). 변경 모듈을
/// `reparseChangedModulePreserveEdges` 가 deinit(=parse_arena free)하면, 그 모듈이 dep 의
/// `requested_exports[dep].names` 에 기여한 slice 가 dangling 된다(dep 는 unchanged 라 안 건드림).
/// 다음 재resolve 의 `requestNamed`→`contains`(std.mem.eql)가 freed 메모리를 읽어 **UAF**(#4123 PR-3
/// /code-review max HIGH). reset 해도 변경 모듈 재resolve 가 자기 deps 요청을 다시 채우고,
/// requested_exports 소비처(lazy-barrel link/tree-shake)는 보존 경로의 dev 게이트(canPreserveTopology
/// 의 `!dev_mode` + isLazyBarrelCandidate 의 dev=false)에서 비활성이라 정확성 영향 0.
/// worker_entries 는 feature gate 가 비어있음을 보장(누적 0). rn_asset_metadata(PR-1)는 finalize 의
/// collectRnAssetMetadata 가 module-level 재수집하므로 reset 불요. runtime_polyfill_roots/
/// run_before_main(PR-2)은 **보존 대상**이라 reset 하면 안 된다 — 게이트를 풀어 보존 경로로 진입하므로
/// roots/rbm 을 비우면 bundler.zig merge 의 prelude 가 깨진다(변경 모듈 feature 불변 검증은
/// buildIncrementalPreserved 의 feature-diff 가드가 담당).
fn resetPerBuildStateForPreserved(self: *ModuleGraph) void {
    for (self.owned_diagnostic_strings.items) |s| self.allocator.free(s);
    self.owned_diagnostic_strings.clearRetainingCapacity();
    self.diagnostics.clearRetainingCapacity();
    self.source_read_cache.deinit(self.allocator);
    self.source_read_cache = .{};
    self.exec_counter = 0;
    self.cycle_counter = 0;
    var req_it = self.requested_exports.valueIterator();
    while (req_it.next()) |req| req.deinit(self.allocator);
    self.requested_exports.clearRetainingCapacity();
}

/// 변경 모듈을 **edge 보존**하며 재파싱한다. dependencies/importers/dynamic_imports/
/// dynamic_importers 리스트(graph allocator 소유, parse_arena 와 독립)를 떼어 보관 →
/// module.deinit(parse_arena/ast/semantic/resolved_deps + edge 리스트 해제) → 같은 index/path
/// 로 빈 Module init → 보관한 edge 리스트 복원 → 재파싱. 재resolve 는 caller 가 suppress_edge_link
/// 로 link 를 억제하므로 edge 가 중복/이동 없이 그대로 유지된다.
fn reparseChangedModulePreserveEdges(self: *ModuleGraph, io: std.Io, mod_idx: usize) void {
    const m = self.modules.at(mod_idx);
    const saved_index = m.index;
    const saved_path = m.path;
    // edge 리스트 move-out (deinit 가 해제하지 않도록 빈 리스트로 치환).
    const saved_deps = m.dependencies;
    const saved_importers = m.importers;
    const saved_dyn = m.dynamic_imports;
    const saved_dyn_importers = m.dynamic_importers;
    // **file-identity 필드 보존**: body edit 은 같은 파일(같은 확장자/loader)이므로 module_type/
    // loader/resolve_dir 이 불변이다. Module.init 은 이들을 default(.unknown) 로 두므로(addModule
    // WithResolveDir 가 확장자로 채우는 로직을 우회), 보존하지 않으면 parseModule 이 모듈을
    // 비-JS 로 오인해 빈 source/0 record 로 끝난다(byte-identical 깨짐). resolve_dir 은 graph
    // allocator 소유라 m.deinit 가 free 하므로 move-out 후 복원.
    const saved_module_type = m.module_type;
    const saved_loader = m.loader;
    const saved_resolve_dir = m.resolve_dir;
    // asset 모듈(asset_registry 모드 .file/.copy)은 emit 후 loader 가 .javascript 로 굳는다.
    // 그 .javascript 를 그대로 복원하면 parseModule 의 isAsset() 분기를 못 타 parseAssetModule 이
    // 미실행되어 metadata 손실 + 바이너리를 raw JS 로 오파싱한다. asset_data.original_loader(원본
    // .file/.copy)를 복원해 재파싱이 asset 로 다시 해석되게 한다 — source 는 Module.init 의 빈 값으로
    // 둬 분기 진입(parse_module:62). 새 hash/scales/metadata + AssetRegistry import(specifier 불변)로
    // 보존 경로 유지(fallback 불요).
    const saved_asset_loader: ?types.Loader = if (m.asset_data) |ad| ad.original_loader else null;
    // polyfill/inject 주입 모듈(is_context_dep)은 applyRuntimePolyfills 에서만 set 되는데 보존 경로는
    // 그걸 미호출하므로, 변경 모듈이 그런 모듈이면(드묾 — core-js/InitializeCore 편집) reparse 의
    // Module.init default(false)로 플래그를 잃는다. 복원해 finalize 의 wrap_kind 강제를 유지(fallback 불요).
    const saved_is_context_dep = m.is_context_dep;
    m.dependencies = .empty;
    m.importers = .empty;
    m.dynamic_imports = .empty;
    m.dynamic_importers = .empty;
    m.resolve_dir = null; // move-out: m.deinit 가 free 하지 않게(아래에서 복원).
    // 나머지(parse_arena/ast/semantic/resolved_deps/import_records/alias_table 등) 일괄 해제.
    m.deinit(self.allocator);
    // 같은 index/path 로 빈 Module — edge + file-identity 복원.
    m.* = @import("../module.zig").Module.init(saved_index, saved_path);
    m.dependencies = saved_deps;
    m.importers = saved_importers;
    m.dynamic_imports = saved_dyn;
    m.dynamic_importers = saved_dyn_importers;
    m.module_type = saved_module_type;
    m.loader = if (saved_asset_loader) |al| al else saved_loader;
    m.resolve_dir = saved_resolve_dir;
    m.is_context_dep = saved_is_context_dep;

    // 재파싱(새 parse_arena + ast + import_records). mtime=0 → parseModule 이
    // readModuleSourceWithMtime 로 fresh source + mtime 을 채운다.
    m.mtime = 0;
    self.parseModule(io, ModuleIndex.fromUsize(mod_idx));
    const m2 = self.modules.at(mod_idx);
    self.applySideEffectsFromPackageJson(io, m2);
    m2.state = .ready;
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

// ============================================================
// perf/hmr-graph-topology-reuse Phase A — topology snapshot/guard primitive 단위 테스트
//
// 이 테스트들이 corruption 방어의 핵심: snapshot 이 deinit 전에 (specifier,kind,target)을
// 정확히 떠서, 재파싱 후 위상 동일/변화를 정확히 판정하는지 검증한다. graph 는 직접 조립
// (addModule + parse_arena 소유 import_records) 해 resolve 파이프라인 없이 primitive 만 격리.
// ============================================================

const ResolveCache_t = @import("../resolve_cache.zig").ResolveCache;
const ImportRecord_t = types.ImportRecord;
const Span_t = @import("../../lexer/token.zig").Span;

/// 테스트 헬퍼: 모듈의 import_records 를 parse_arena 소유로 세팅한다.
/// (specifier, kind, resolved) 튜플 리스트로부터 record 를 만든다.
fn tSetRecords(
    graph: *ModuleGraph,
    idx: usize,
    recs: []const struct { spec: []const u8, kind: types.ImportKind, resolved: i64 },
) !void {
    const m = graph.modules.at(idx);
    if (m.parse_arena == null) {
        m.parse_arena = @import("../module.zig").createParseArena(graph.allocator) orelse return error.OutOfMemory;
    }
    const pa = m.parse_arena.?.allocator();
    const out = try pa.alloc(ImportRecord_t, recs.len);
    for (recs, 0..) |r, i| {
        out[i] = .{
            .specifier = try pa.dupe(u8, r.spec),
            .kind = r.kind,
            .span = Span_t.EMPTY,
            .resolved = if (r.resolved < 0) types.ModuleIndex.none else types.ModuleIndex.fromUsize(@intCast(r.resolved)),
        };
    }
    m.import_records = out;
}

test "topology: body-only edit 는 위상 동일 판정(보존 가능)" {
    var cache = ResolveCache_t.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    // 0=index, 1=util. index → util (static). util → (none).
    _ = try graph.addModule(std.testing.io, "/p/index.ts");
    _ = try graph.addModule(std.testing.io, "/p/util.ts");
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .static_import, .resolved = 1 }});

    var snap = (try snapshotModuleTopology(&graph, std.testing.allocator, 0)).?;
    defer snap.deinit();

    // body-only: 같은 record 로 재구성 (재파싱 시뮬레이션) → 위상 동일.
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .static_import, .resolved = 1 }});
    try std.testing.expect(topologyMatches(&snap, &graph, 0));
}

test "topology: import specifier 추가 → 위상 변화(full)" {
    var cache = ResolveCache_t.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    _ = try graph.addModule(std.testing.io, "/p/index.ts");
    _ = try graph.addModule(std.testing.io, "/p/util.ts");
    _ = try graph.addModule(std.testing.io, "/p/extra.ts");
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .static_import, .resolved = 1 }});

    var snap = (try snapshotModuleTopology(&graph, std.testing.allocator, 0)).?;
    defer snap.deinit();

    // specifier 1 개 추가 → record_count 변화 → 불일치.
    try tSetRecords(&graph, 0, &.{
        .{ .spec = "./util", .kind = .static_import, .resolved = 1 },
        .{ .spec = "./extra", .kind = .static_import, .resolved = 2 },
    });
    try std.testing.expect(!topologyMatches(&snap, &graph, 0));
}

test "topology: 같은 specifier 가 다른 파일로 resolve → resolve-diff(full)" {
    var cache = ResolveCache_t.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    // 0=index, 1=util-old, 2=util-new. 같은 './util' specifier 가 1→2 로 타겟 변경.
    _ = try graph.addModule(std.testing.io, "/p/index.ts");
    _ = try graph.addModule(std.testing.io, "/p/util-old.ts");
    _ = try graph.addModule(std.testing.io, "/p/util-new.ts");
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .static_import, .resolved = 1 }});

    var snap = (try snapshotModuleTopology(&graph, std.testing.allocator, 0)).?;
    defer snap.deinit();

    // specifier 동일하지만 resolve 타겟 path 가 다름 → resolve-diff → 불일치.
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .static_import, .resolved = 2 }});
    try std.testing.expect(!topologyMatches(&snap, &graph, 0));
}

test "topology: static → dynamic kind 변화 → 위상 변화(full)" {
    var cache = ResolveCache_t.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    _ = try graph.addModule(std.testing.io, "/p/index.ts");
    _ = try graph.addModule(std.testing.io, "/p/util.ts");
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .static_import, .resolved = 1 }});

    var snap = (try snapshotModuleTopology(&graph, std.testing.allocator, 0)).?;
    defer snap.deinit();

    // 같은 specifier/target 이지만 static → dynamic → 불일치(dynamic_import diff).
    try tSetRecords(&graph, 0, &.{.{ .spec = "./util", .kind = .dynamic_import, .resolved = 1 }});
    try std.testing.expect(!topologyMatches(&snap, &graph, 0));
}

test "topology: glob record 는 스냅샷 거부(null → 보수적 full)" {
    var cache = ResolveCache_t.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    _ = try graph.addModule(std.testing.io, "/p/index.ts");
    try tSetRecords(&graph, 0, &.{.{ .spec = "./pages/*.ts", .kind = .glob, .resolved = -1 }});

    // glob 는 build-time FS 확장이라 위상 보존 대상 아님 → snapshot=null.
    const snap = try snapshotModuleTopology(&graph, std.testing.allocator, 0);
    try std.testing.expect(snap == null);
}
