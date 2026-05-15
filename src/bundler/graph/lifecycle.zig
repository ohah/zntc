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
        // modules 는 default (.{}) 로 빈 SegmentedList.
        .path_to_module = std.StringHashMap(ModuleIndex).init(allocator),
        .diagnostics = .empty,
        .resolve_cache = resolve_cache,
    };
}

pub fn deinit(self: *ModuleGraph) void {
    var mod_it = self.modules.iterator(0);
    while (mod_it.next()) |m| {
        // import_records, import_bindings, export_bindings는 parse_arena 소유.
        // parse_arena.deinit()이 일괄 해제하므로 명시적 free 불필요.
        m.deinit(self.allocator); // parse_arena.deinit() + dependencies/importers 해제
    }
    self.modules.deinit(self.allocator);
    var key_it = self.path_to_module.keyIterator();
    while (key_it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.path_to_module.deinit();
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
