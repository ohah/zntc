//! ModuleGraph construction and teardown helpers.

const std = @import("std");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const resolve_cache_mod = @import("../resolve_cache.zig");
const ResolveCache = resolve_cache_mod.ResolveCache;

pub fn init(allocator: std.mem.Allocator, resolve_cache: *ResolveCache) ModuleGraph {
    return .{
        .allocator = allocator,
        .path_arena = std.heap.ArenaAllocator.init(allocator),
        // modules 는 default (.{}) 로 빈 SegmentedList.
        .path_to_module = .empty,
        .diagnostics = .empty,
        .resolve_cache = resolve_cache,
    };
}

/// graph-global state 만 reset — modules / path_to_module / path_arena / pkg_info_cache 는
/// 보존. RFC_GRAPH_PERSISTENCE Sub-PR-B.1 의 API skeleton — 호출자 없음 (테스트 only).
///
/// Reset 영역:
///   - diagnostics + owned_diagnostic_strings (매 빌드마다 새 diag)
///   - worker_entries (매 빌드마다 새로 수집, resolved_path 는 graph allocator 소유)
///   - rn_asset_metadata (매 빌드마다 새로 수집)
///   - runtime_polyfill_roots (매 빌드마다 새로 수집)
///   - requested_exports (graph-level state, ancestor 추적 어려워 일괄 reset)
///   - source_read_cache (다음 빌드에서 fresh read 강제)
///   - exec_counter / cycle_counter (DFS state)
///
/// **보존 영역 (persistence 의 핵심):**
///   - modules SegmentedList — module 인스턴스 그대로
///   - path_to_module — path → idx 인덱스
///   - path_arena — path/resolve_dir 메모리
///   - pkg_info_cache — package.json 정보 (재 parse 회피)
///   - 옵션들 (dev_mode, jsx_runtime, defines, plugins 등)
///
/// 사용 가정: caller 가 변경 모듈에 대해 invalidateModule(idx) 를 추가로 호출해
/// 모듈 단위 state 도 reset. reset() 만 호출하면 modules 의 stale ast/semantic 이
/// 그대로 남음 — Sub-PR-B.3 의 wire-up 에서 invalidateModule 와 함께 사용.
pub fn reset(self: *ModuleGraph) void {
    for (self.owned_diagnostic_strings.items) |s| self.allocator.free(s);
    self.owned_diagnostic_strings.clearRetainingCapacity();
    self.diagnostics.clearRetainingCapacity();

    for (self.worker_entries.items) |we| self.allocator.free(we.resolved_path);
    self.worker_entries.clearRetainingCapacity();

    // rn_asset_metadata 항목은 module.parse_arena 소유(borrow) — 여기서 free 안 함.
    // finalize 의 collectRnAssetMetadata 가 clear 후 module 들에서 재수집한다.
    self.rn_asset_metadata.clearRetainingCapacity();

    self.runtime_polyfill_roots.clearRetainingCapacity();

    var req_it = self.requested_exports.valueIterator();
    while (req_it.next()) |req| req.deinit(self.allocator);
    self.requested_exports.clearRetainingCapacity();

    // #4074 방어: lazy_seeds 도 per-build 상태다. 현재는 매 rebuild 가 fresh graph 라
    // 무관하지만, graph persistence(RFC #3933)로 reset() 재사용이 도입되면 비우지 않을 시
    // 이전 빌드 seed 가 누적돼 materializeLazySeeds 가 fresh module set 에 stale seed 를
    // 처리한다. path/resolve_dir 은 path_arena 소유라 clearRetainingCapacity 로 충분(개별 free 불요).
    self.lazy_seeds.clearRetainingCapacity();

    self.source_read_cache.deinit(self.allocator);
    self.source_read_cache = .{};

    self.exec_counter = 0;
    self.cycle_counter = 0;
    // #4520: wrap_kind 확정 잠금은 per-build 상태 — 매 빌드 promoteExportsKinds 가 다시 확정한다.
    // 안 풀면 rebuild 의 변경 모듈 재파스-resync 가 최초 분류를 건너뛰어 stale wrap_kind 가 남는다.
    self.wrap_kinds_finalized = false;

    // requestDependencyExports CSR 캐시 무효화 — rebuild 후 같은 importer_idx 의 binding 이
    // 바뀌어도 stale 캐시를 재사용하지 않도록. backing 은 보존(clearRetainingCapacity 재사용).
    self.rdx_cache_owner = null;
}

/// 단일 모듈의 state 부분 reset (path 보존, graph slot 유지). 변경 감지된 모듈을
/// re-parse/re-analyze 하기 전 호출. 인덱스 자체는 path_to_module 에서 유지되어
/// 다른 모듈의 dependencies/importers 가 가리키는 ModuleIndex 가 그대로 유효.
///
/// 동작: module.deinit() 으로 ast/semantic/resolved_deps 등 모든 resource 해제 →
/// 동일 index/path 로 빈 Module 새로 init (state = .reserved). 이후 caller 가
/// 정상 build flow (read → parse → semantic → resolve) 로 다시 채움.
///
/// **importers / dynamic_importers 보존**: 다른 모듈이 이 모듈을 import 하는 정보는
/// 이번 변경과 무관 — caller (정상 build flow) 가 같은 importers 를 다시 채움.
/// 실제로는 module.deinit 가 importers/dependencies 둘 다 해제하지만, init 후 caller
/// 가 build flow 에서 importers 재기록함.
pub fn invalidateModule(self: *ModuleGraph, idx: ModuleIndex) void {
    const idx_usize = @intFromEnum(idx);
    std.debug.assert(idx_usize < self.modules.count());
    const mod_ptr = self.modules.at(idx_usize);
    const saved_path = mod_ptr.path;
    const saved_index = mod_ptr.index;
    mod_ptr.deinit(self.allocator);
    mod_ptr.* = @import("../module.zig").Module.init(saved_index, saved_path);
}

/// perf/hmr-graph-topology-reuse Phase A — persistent_graph 재사용 빌드 직전 호출.
///
/// **현재(Phase A) 의미 = "fresh 와 byte-identical 한 안전 reset"**:
/// graph 인스턴스(SegmentedList backing, path_to_module backing, path_arena, 옵션,
/// pkg_info_cache)는 보존하되, **모든 모듈 슬롯을 비우고**(`modules` clear) graph-global
/// state 를 reset 한다. 이후 `buildIncremental` 이 entry 부터 다시 discovery 하며 슬롯을
/// 새로 append → 출력은 매 빌드 fresh graph 와 동일.
///
/// **왜 슬롯 in-place 보존(invalidateModule)이 아니라 전량 clear 인가 (정확성 근거):**
///   1. body-only edit 의 위상 보존(edge/exec_index 재사용)은 `transferModulesToStore`
///      (build_flow:transferModulesToStore)가 매 빌드 graph 모듈의 parse_arena /
///      import_records / resolved_deps 소유권을 store 로 *이전*(=graph 쪽을 비움)하는 한
///      불가능하다. 그 소유권 재설계는 plan 의 **Phase B(최대 리스크)** 라 Phase A 범위 밖.
///   2. invalidateModule 로 슬롯만 `.reserved` 로 되돌리고 보존하면, **모듈이 제거되는
///      위상 변화**에서 옛 슬롯이 orphan 으로 남는다. `buildIncremental` 의 sequential
///      루프는 `parse_start..modules.count()` 전 범위를 돌며 `.reserved` 슬롯을 무조건
///      reparse → emitter(emitter.zig:400 `m.ast != null` 필터)가 *더 이상 import 되지
///      않는 제거된 모듈을 그대로 emit* → silent corruption. `path_to_module` 도 그 orphan
///      을 가리켜 다음 빌드 dedup 이 stale 슬롯을 hit.
///   → 따라서 Phase A 는 슬롯을 보존하지 않는다. clear 후 fresh discovery 가 유일하게
///      byte-identical 을 보장하는 경로다. (slot/edge 재사용은 Phase B 에서
///      transferModulesToStore 비활성 + orphan prune 과 함께 도입.)
///
/// **보존 영역**: graph struct 자체(call-site 가 deinit/재init 을 피함 — 객체 수명 안정),
/// modules SegmentedList 의 *backing chunk*(clearRetainingCapacity 로 재사용),
/// path_to_module *backing*(clear 후 재채움), path_arena.
///
/// **재설정(reset) 영역**: reset() 가 비우는 graph-global state 전체 + modules + path_to_module.
///
/// path_arena: clearRetainingCapacity 로 **메모리 보존 + 논리적 비움**. 이전 빌드 path
/// 슬라이스는 modules/path_to_module 가 비워져 더 이상 참조되지 않으므로 재사용 안전
/// (monotonic 누적 없이 capacity 재활용). retainCapacity 라 RSS 단방향 증가 없음.
///
/// **pkg_info_cache 무효화 (F1)**: path_arena 를 recycle 하면 pkg_info_cache 키
/// (= module_path 의 substring, path_arena 소유)가 dangling 되므로 reset 직전에 비운다.
/// reset() 는 path_arena 를 유지해 키가 살아있으니 pkg_info_cache 를 보존(doc 계약)하지만,
/// 여기서는 path_arena 가 회수되므로 보존이 불가능 — value 메모리 해제 후 clearRetainingCapacity.
pub fn prepareForPreservedRebuild(self: *ModuleGraph) void {
    // 1) 모든 모듈 슬롯 해제 (parse_arena 가 아직 graph 소유면 함께 해제 —
    //    transferModulesToStore 가 이미 store 로 넘긴 경우 parse_arena=null 이라 no-op).
    var mod_it = self.modules.iterator(0);
    while (mod_it.next()) |m| {
        m.deinit(self.allocator);
    }
    self.modules.clearRetainingCapacity();

    // 2) path → idx 인덱스 비움 (backing 재사용).
    self.path_to_module.clearRetainingCapacity();

    // 2.5) pkg_info_cache 비움 — **path_arena.reset 전에 반드시** (F1 dangling key).
    //   키는 graph.zig:112 주석대로 module_path 의 substring(= path_arena 소유, dupe 없음).
    //   아래 3) 에서 path_arena 를 recycle 하면 그 키 슬라이스가 회수된 arena 를 가리켜
    //   dangling → 다음 빌드의 lookupPkgInfo(get) 가 stale is_module/side_effects 반환 →
    //   잘못된 ESM/tree-shaking 판정(silent corruption). 보존 경로(prepareForPreservedRebuild)
    //   에서만 path_arena 를 recycle 하므로, pkg_info_cache 무효화도 여기 한정이 맞다
    //   (reset() 는 path_arena 를 유지해 키가 살아있으므로 pkg_info_cache 를 보존 — 그게 doc 계약).
    //   value 소유 메모리(side_effects.patterns: graph.allocator dupe)는 graph.deinit
    //   (graph.zig pkg_info_cache 해제 loop)과 **동일한 방식**으로 free 후 backing 재사용.
    var pi_it = self.pkg_info_cache.valueIterator();
    while (pi_it.next()) |info| info.side_effects.deinit(self.allocator);
    self.pkg_info_cache.clearRetainingCapacity();

    // 3) path_arena 논리적 비움 + capacity 보존 (위 doc: 더 이상 참조 없음).
    _ = self.path_arena.reset(.retain_capacity);

    // 4) entry_dir 은 graph-owned dupe — buildIncremental 의 entry_dir 재계산이 free 후
    //    재dupe 하므로 여기서 건드리지 않는다(이중 free 방지). project_root 자동 추론도 동일.

    // 5) graph-global per-build state reset (diagnostics / worker_entries / lazy_seeds /
    //    requested_exports / source_read_cache / exec/cycle counter).
    reset(self);
}

pub fn deinit(self: *ModuleGraph) void {
    // 0.16: entry_dir 는 graph-owned dupe (build_flow). project_root 는 entry_dir
    // 로의 borrow 또는 user-set borrow 라 별도 free 안 함.
    if (self.entry_dir.len > 0) self.allocator.free(self.entry_dir);
    var mod_it = self.modules.iterator(0);
    while (mod_it.next()) |m| {
        // import_records, import_bindings, export_bindings는 parse_arena 소유.
        // parse_arena.deinit()이 일괄 해제하므로 명시적 free 불필요.
        m.deinit(self.allocator); // parse_arena.deinit() + dependencies/importers 해제
    }
    self.modules.deinit(self.allocator);
    // PR-Z4: path_to_module key 메모리는 path_arena 가 owned — 개별 free 불요, 일괄 해제.
    self.path_to_module.deinit(self.allocator);
    // PR-B: changed_emit_paths key 는 path_arena borrow — set backing 만 해제(path_arena 보다 먼저).
    if (self.changed_emit_paths) |*s| s.deinit(self.allocator);
    self.path_arena.deinit();
    var req_it = self.requested_exports.valueIterator();
    while (req_it.next()) |req| req.deinit(self.allocator);
    self.requested_exports.deinit(self.allocator);
    var pi_it = self.pkg_info_cache.valueIterator();
    while (pi_it.next()) |info| info.side_effects.deinit(self.allocator);
    self.pkg_info_cache.deinit(self.allocator);
    self.source_read_cache.deinit(self.allocator);
    for (self.owned_diagnostic_strings.items) |s| self.allocator.free(s);
    self.owned_diagnostic_strings.deinit(self.allocator);
    self.diagnostics.deinit(self.allocator);
    for (self.worker_entries.items) |we| {
        self.allocator.free(we.resolved_path);
    }
    self.worker_entries.deinit(self.allocator);
    // rn_asset_metadata 항목은 module.parse_arena 소유(borrow) — list backing 만 해제.
    self.rn_asset_metadata.deinit(self.allocator);
    if (self.plugins_with_helpers) |p| self.allocator.free(p);
    self.runtime_polyfill_roots.deinit(self.allocator);
    // PR-3a lazy seeds — path 는 path_arena 소유라 리스트 자체만 해제.
    self.lazy_seeds.deinit(self.allocator);
    // requestDependencyExports per-importer CSR 캐시 (self.allocator 소유).
    self.rdx_offsets.deinit(self.allocator);
    self.rdx_order.deinit(self.allocator);
}
