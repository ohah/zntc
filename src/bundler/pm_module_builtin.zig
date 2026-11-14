//! Constructor-owned synchronous module environment. Public CJS values never serve as brands.
const std = @import("std");
const Graph = @import("graph.zig").ModuleGraph;
const Builtin = @import("graph.zig").TlaReadinessAll;
const SymbolID = @import("symbol.zig").SymbolID;
pub const id = "\x00zntc:runtime/pm-module";

fn checkedProvider(graph: *const Graph, index: @import("types.zig").ModuleIndex) !*const @import("module.zig").Module {
    const provider = graph.getModule(index) orelse return error.InvalidPmModuleBuiltin;
    const origin = provider.runtime_helper_source orelse return error.InvalidPmModuleBuiltin;
    if (origin.catalog != .pm_module or
        !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, provider.source) or
        provider.index != index or provider.codegen_output_owner == .unassigned or
        provider.dependencies.items.len != 0 or provider.self_uses_top_level_await or provider.uses_top_level_await or
        provider.tla_iife_stmt != null) return error.InvalidPmModuleBuiltin;
    const semantic = provider.semantic orelse return error.InvalidPmModuleBuiltin;
    if (semantic.owner_token == .unassigned) return error.InvalidPmModuleBuiltin;
    return provider;
}

pub fn keepSynchronous(graph: *Graph) !void {
    if (!graph.pm_cjs_module_environments) return;
    const index = graph.path_to_module.get(id) orelse return;
    const provider = graph.moduleAtMut(index) orelse return error.InvalidPmModuleBuiltin;
    const semantic = if (provider.semantic) |*value| value else return error.InvalidPmModuleBuiltin;
    if (semantic.captureOwnerToken() == .unassigned) return error.InvalidPmModuleBuiltin;
    _ = try checkedProvider(graph, index);
    provider.wrap_kind = .none;
}

pub fn capture(graph: *const Graph) !?Builtin {
    if (!graph.pm_cjs_module_environments) return null;
    const index = graph.path_to_module.get(id) orelse return null;
    const provider = try checkedProvider(graph, index);
    if (provider.wrap_kind != .none) return error.InvalidPmModuleBuiltin;
    const exports = @import("../runtime_helper_modules.zig").catalogExports(.pm_module);
    if (exports.len != 1) return error.InvalidPmModuleBuiltin;
    var result: ?Builtin = null;
    for (provider.export_bindings, 0..) |binding, i| {
        if (!std.mem.eql(u8, binding.exported_name, exports[0])) continue;
        if (result != null) return error.InvalidPmModuleBuiltin;
        const sid = provider.exportBindingLocalNodeSemanticIndex(binding) orelse return error.InvalidPmModuleBuiltin;
        result = .{ .module_index = index, .export_index = @intCast(i), .symbol_id = @fromBackingInt(sid), .owner_token = provider.semantic.?.owner_token };
    }
    return result orelse error.InvalidPmModuleBuiltin;
}

pub fn exact(graph: *const Graph) !SymbolID {
    const known = graph.pm_module_builtin orelse return error.InvalidPmModuleBuiltin;
    const actual = (try capture(graph)) orelse return error.InvalidPmModuleBuiltin;
    if (!std.meta.eql(known, actual)) return error.InvalidPmModuleBuiltin;
    return SymbolID.make(known.module_index, @backingInt(known.symbol_id));
}
