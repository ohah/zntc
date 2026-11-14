//! Constructor-owned default bridge. Public CJS values never serve as brands.
const std = @import("std");
const Graph = @import("graph.zig").ModuleGraph;
const Builtin = @import("graph.zig").TlaReadinessAll;
const SymbolID = @import("symbol.zig").SymbolID;
pub const id = "\x00zntc:runtime/pm-default";

fn checkedProvider(graph: *const Graph, index: @import("types.zig").ModuleIndex) !*const @import("module.zig").Module {
    const provider = graph.getModule(index) orelse return error.InvalidPmDefaultBuiltin;
    const origin = provider.runtime_helper_source orelse return error.InvalidPmDefaultBuiltin;
    if (origin.catalog != .pm_default or
        !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, provider.source) or
        provider.index != index or provider.codegen_output_owner == .unassigned or
        provider.dependencies.items.len != 0 or provider.self_uses_top_level_await or provider.uses_top_level_await or
        provider.tla_iife_stmt != null) return error.InvalidPmDefaultBuiltin;
    const semantic = provider.semantic orelse return error.InvalidPmDefaultBuiltin;
    if (semantic.owner_token == .unassigned) return error.InvalidPmDefaultBuiltin;
    return provider;
}

pub fn keepSynchronous(graph: *Graph) !void {
    if (!graph.pm_cjs_default_bindings) return;
    const index = graph.path_to_module.get(id) orelse return;
    const provider = graph.moduleAtMut(index) orelse return error.InvalidPmDefaultBuiltin;
    const semantic = if (provider.semantic) |*value| value else return error.InvalidPmDefaultBuiltin;
    if (semantic.captureOwnerToken() == .unassigned) return error.InvalidPmDefaultBuiltin;
    _ = try checkedProvider(graph, index);
    provider.wrap_kind = .none;
}

pub fn capture(graph: *const Graph) !?Builtin {
    if (!graph.pm_cjs_default_bindings) return null;
    const index = graph.path_to_module.get(id) orelse return null;
    const provider = try checkedProvider(graph, index);
    if (provider.wrap_kind != .none) return error.InvalidPmDefaultBuiltin;
    const exports = @import("../runtime_helper_modules.zig").catalogExports(.pm_default);
    if (exports.len != 1) return error.InvalidPmDefaultBuiltin;
    var result: ?Builtin = null;
    for (provider.export_bindings, 0..) |binding, i| {
        if (!std.mem.eql(u8, binding.exported_name, exports[0])) continue;
        if (result != null) return error.InvalidPmDefaultBuiltin;
        const sid = provider.exportBindingLocalNodeSemanticIndex(binding) orelse return error.InvalidPmDefaultBuiltin;
        result = .{ .module_index = index, .export_index = @intCast(i), .symbol_id = @fromBackingInt(sid), .owner_token = provider.semantic.?.owner_token };
    }
    return result orelse error.InvalidPmDefaultBuiltin;
}

pub fn exact(graph: *const Graph) !SymbolID {
    const known = graph.pm_default_builtin orelse return error.InvalidPmDefaultBuiltin;
    const actual = (try capture(graph)) orelse return error.InvalidPmDefaultBuiltin;
    if (!std.meta.eql(known, actual)) return error.InvalidPmDefaultBuiltin;
    return SymbolID.make(known.module_index, @backingInt(known.symbol_id));
}
