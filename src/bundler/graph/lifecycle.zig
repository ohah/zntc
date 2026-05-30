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

    const graph_assets = @import("assets.zig");
    for (self.rn_asset_metadata.items) |meta| {
        graph_assets.freeRnAssetMetadata(self.allocator, meta);
    }
    self.rn_asset_metadata.clearRetainingCapacity();

    self.runtime_polyfill_roots.clearRetainingCapacity();

    var req_it = self.requested_exports.valueIterator();
    while (req_it.next()) |req| req.deinit(self.allocator);
    self.requested_exports.clearRetainingCapacity();

    self.source_read_cache.deinit(self.allocator);
    self.source_read_cache = .{};

    self.exec_counter = 0;
    self.cycle_counter = 0;
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
    const graph_assets = @import("assets.zig");
    for (self.rn_asset_metadata.items) |meta| {
        graph_assets.freeRnAssetMetadata(self.allocator, meta);
    }
    self.rn_asset_metadata.deinit(self.allocator);
    if (self.plugins_with_helpers) |p| self.allocator.free(p);
    self.runtime_polyfill_roots.deinit(self.allocator);
}
