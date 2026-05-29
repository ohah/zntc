//! Post-discovery deterministic renumber of ModuleIndex.
//!
//! 호출 시점 안전성:
//!   - discovery 워커 모두 join 완료 (linkExecutionRoots 직후) — 외부 *Module 보유자 없음
//!   - linker init 전 — linker.export_map 등 idx-키 자료구조 미존재
//!
//! 메모리 안전성:
//!   - 새 ModuleList 에 Module struct 얕은 복사 — ArrayList ptr / parse_arena 동일 ref 공유
//!   - 기존 ModuleList 는 `deinit` 으로 shelf 만 free (Module.deinit 우회) — 새 list ref 보존
//!   - 후속 graph.deinit() 시 새 list 의 Module.deinit 이 backing 정상 해제

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const ModuleList = ModuleGraph.ModuleList;
const RequestedExports = @import("state.zig").RequestedExports;
const bundler_symbol = @import("../symbol.zig");
const profile = @import("../../profile.zig");

pub const RenumberError = error{ RenumberIncomplete, OutOfMemory };

pub fn renumberModulesDeterministically(
    self: *ModuleGraph,
    entry_points: []const []const u8,
) RenumberError!void {
    var scope = profile.begin(.graph_renumber);
    defer scope.end();

    const old_count = self.modules.count();
    if (old_count == 0) return;
    std.debug.assert(old_count <= std.math.maxInt(u32));

    const allocator = self.allocator;

    var old_to_new = try allocator.alloc(u32, old_count);
    defer allocator.free(old_to_new);
    var new_to_old = try allocator.alloc(u32, old_count);
    defer allocator.free(new_to_old);

    var visited = try std.DynamicBitSet.initEmpty(allocator, old_count);
    defer visited.deinit();

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    try queue.ensureTotalCapacity(allocator, old_count);

    var new_idx: u32 = 0;

    // seed 순서 = build_flow 의 add 순서 (inject → run-before-main → entry) 로 cold/incremental 동등.
    try seedFromPaths(self, self.inject_files, &visited, &queue);
    try seedFromPaths(self, self.run_before_main_files, &visited, &queue);
    try seedFromPaths(self, entry_points, &visited, &queue);

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const old_u32 = queue.items[head];
        old_to_new[old_u32] = new_idx;
        new_to_old[new_idx] = old_u32;
        new_idx += 1;

        const m = self.modules.at(old_u32);
        for (m.import_records) |rec| {
            try visitDep(rec.resolved, old_count, &visited, &queue, allocator);
        }
        for (m.dynamic_imports.items) |dep| {
            try visitDep(dep, old_count, &visited, &queue, allocator);
        }
    }

    var orphans: std.ArrayList(u32) = .empty;
    defer orphans.deinit(allocator);
    var i: u32 = 0;
    while (i < old_count) : (i += 1) {
        if (!visited.isSet(i)) try orphans.append(allocator, i);
    }
    std.mem.sort(u32, orphans.items, self, lessThanByPath);
    for (orphans.items) |old_u32| {
        old_to_new[old_u32] = new_idx;
        new_to_old[new_idx] = old_u32;
        new_idx += 1;
    }
    if (new_idx != old_count) return error.RenumberIncomplete;

    var new_list: ModuleList = .{};
    errdefer new_list.deinit(allocator);
    for (0..old_count) |new_i| {
        const old_u32 = new_to_old[new_i];
        var m = self.modules.at(old_u32).*;
        m.index = ModuleIndex.fromUsize(new_i);
        try new_list.append(allocator, m);
    }

    var nlit = new_list.iterator(0);
    while (nlit.next()) |m| {
        remapList(&m.dependencies, old_to_new);
        remapList(&m.importers, old_to_new);
        remapList(&m.dynamic_imports, old_to_new);
        remapList(&m.dynamic_importers, old_to_new);
        // #3664: implicitlyLoadedAfterOneOf 양방향 관계도 ModuleIndex 보유 → renumber 시 remap.
        // (injectEmittedChunks 가 renumber 전에 채우므로 안 하면 stale 인덱스 → 엉뚱한 모듈 보고.)
        remapList(&m.implicitly_loaded_after_one_of, old_to_new);
        remapList(&m.implicitly_loaded_before, old_to_new);
        for (m.import_records) |*rec| {
            if (rec.resolved.isNone()) continue;
            rec.resolved = @enumFromInt(old_to_new[rec.resolved.toU32()]);
        }
        // binding_scanner 가 scan 시점 (renumber 전) module_index 를 SymbolRef 에 박음.
        // ImportBinding.symbol/local_symbol + ExportBinding.symbol 의 .semantic.module / .alias.module
        // 필드를 renumber 후 새 idx 로 일괄 치환 — cross-module symbol resolution 정확성 보장.
        for (m.import_bindings) |*ib| {
            ib.symbol = remapSymbolRef(ib.symbol, old_to_new);
            ib.local_symbol = remapSymbolRef(ib.local_symbol, old_to_new);
        }
        for (m.export_bindings) |*eb| {
            eb.symbol = remapSymbolRef(eb.symbol, old_to_new);
        }
    }

    var p_it = self.path_to_module.iterator();
    while (p_it.next()) |entry| {
        entry.value_ptr.* = @enumFromInt(old_to_new[entry.value_ptr.toU32()]);
    }

    var new_req: std.AutoHashMapUnmanaged(u32, RequestedExports) = .empty;
    errdefer new_req.deinit(allocator);
    try new_req.ensureTotalCapacity(allocator, @intCast(self.requested_exports.count()));
    var r_it = self.requested_exports.iterator();
    while (r_it.next()) |entry| {
        try new_req.put(allocator, old_to_new[entry.key_ptr.*], entry.value_ptr.*);
    }
    self.requested_exports.deinit(allocator);
    self.requested_exports = new_req;

    for (self.worker_entries.items) |*we| {
        we.source_module = @enumFromInt(old_to_new[we.source_module.toU32()]);
    }

    // StableSegmentedList.deinit 은 Module.deinit 을 호출하지 않으므로 새 list 의 얕은 복사
    // ref 가 보존된다 — 이 invariant 가 깨지면 dangling 발생.
    self.modules.deinit(allocator);
    self.modules = new_list;
}

fn seedFromPaths(
    self: *ModuleGraph,
    paths: []const []const u8,
    visited: *std.DynamicBitSet,
    queue: *std.ArrayList(u32),
) !void {
    const old_count = self.modules.count();
    for (paths) |path| {
        const idx_e = self.path_to_module.get(path) orelse continue;
        const old_u32 = idx_e.toU32();
        if (old_u32 >= old_count or visited.isSet(old_u32)) continue;
        visited.set(old_u32);
        try queue.append(self.allocator, old_u32);
    }
}

fn visitDep(
    dep: ModuleIndex,
    old_count: usize,
    visited: *std.DynamicBitSet,
    queue: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
) !void {
    if (dep.isNone()) return;
    const old_u32 = dep.toU32();
    if (old_u32 >= old_count or visited.isSet(old_u32)) return;
    visited.set(old_u32);
    try queue.append(allocator, old_u32);
}

inline fn remapList(list: *std.ArrayList(ModuleIndex), old_to_new: []const u32) void {
    for (list.items) |*idx| {
        idx.* = @enumFromInt(old_to_new[idx.toU32()]);
    }
}

fn remapSymbolRef(ref: bundler_symbol.SymbolRef, old_to_new: []const u32) bundler_symbol.SymbolRef {
    return switch (ref) {
        .semantic => |s| if (s.module.isNone()) ref else .{ .semantic = .{
            .module = @enumFromInt(old_to_new[s.module.toU32()]),
            .symbol = s.symbol,
        } },
        .alias => |a| if (a.module.isNone()) ref else .{ .alias = .{
            .module = @enumFromInt(old_to_new[a.module.toU32()]),
            .symbol = a.symbol,
        } },
    };
}

fn lessThanByPath(graph: *const ModuleGraph, a: u32, b: u32) bool {
    return std.mem.lessThan(u8, graph.modules.at(a).path, graph.modules.at(b).path);
}
