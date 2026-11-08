//! First graph publication of the actual winning TDZ helper constructor.
const std = @import("std");
const SymbolID = @import("symbol.zig").SymbolID;

pub fn capture(graph: anytype) !@TypeOf(graph.lexical_tdz_builtin) {
    var result: @TypeOf(graph.lexical_tdz_builtin) = null;
    var modules = graph.modulesIterator();
    while (modules.next()) |provider| {
        const origin = provider.runtime_helper_source orelse continue;
        if (origin.catalog != .tdz) continue;
        if (result != null or
            !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, provider.source) or
            provider.dependencies.items.len != 0 or provider.self_uses_top_level_await or provider.uses_top_level_await)
            return error.InvalidLexicalInitializationBuiltin;
        const semantic = provider.semantic orelse return error.InvalidLexicalInitializationBuiltin;
        if (semantic.owner_token == .unassigned) return error.InvalidLexicalInitializationBuiltin;
        const exports = @import("../runtime_helper_modules.zig").catalogExports(.tdz);
        if (exports.len != 1) return error.InvalidLexicalInitializationBuiltin;
        var found = false;
        for (provider.export_bindings, 0..) |binding, index| {
            // The immutable catalog export protocol selects this export row;
            // its actual local-node edge supplies the source SymbolId.
            if (!std.mem.eql(u8, binding.exported_name, exports[0])) continue;
            if (found) return error.InvalidLexicalInitializationBuiltin;
            const sid = provider.exportBindingLocalNodeSemanticIndex(binding) orelse return error.InvalidLexicalInitializationBuiltin;
            result = .{ .module_index = provider.index, .export_index = @intCast(index), .symbol_id = @fromBackingInt(sid), .owner_token = semantic.owner_token };
            found = true;
        }
        if (!found) return error.InvalidLexicalInitializationBuiltin;
    }
    return result;
}

pub fn exact(graph: anytype) !SymbolID {
    const known = graph.lexical_tdz_builtin orelse return error.InvalidLexicalInitializationBuiltin;
    const provider = graph.getModule(known.module_index) orelse return error.InvalidLexicalInitializationBuiltin;
    const origin = provider.runtime_helper_source orelse return error.InvalidLexicalInitializationBuiltin;
    const semantic = provider.semantic orelse return error.InvalidLexicalInitializationBuiltin;
    if (origin.catalog != .tdz or semantic.owner_token == .unassigned or semantic.owner_token != known.owner_token or
        !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, provider.source) or
        known.export_index >= provider.export_bindings.len) return error.InvalidLexicalInitializationBuiltin;
    const binding = provider.export_bindings[known.export_index];
    const exports = @import("../runtime_helper_modules.zig").catalogExports(.tdz);
    if (exports.len != 1 or !std.mem.eql(u8, binding.exported_name, exports[0]) or
        provider.exportBindingLocalNodeSemanticIndex(binding) != @backingInt(known.symbol_id)) return error.InvalidLexicalInitializationBuiltin;
    return SymbolID.make(provider.index, @backingInt(known.symbol_id));
}

pub fn captureNames(graph: anytype) !@TypeOf(graph.legacy_name_builtin) {
    if (!@import("graph/legacy_default_names.zig").graphDemand(graph)) return null;
    var result: @TypeOf(graph.legacy_name_builtin) = null;
    var modules = graph.modulesIterator();
    while (modules.next()) |provider| {
        const origin = provider.runtime_helper_source orelse continue;
        if (origin.catalog != .keep_names) continue;
        if (result != null or
            !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, provider.source) or
            provider.dependencies.items.len != 0 or provider.self_uses_top_level_await or provider.uses_top_level_await)
            return error.InvalidDefaultNameBuiltin;
        const semantic = provider.semantic orelse return error.InvalidDefaultNameBuiltin;
        if (semantic.owner_token == .unassigned) return error.InvalidDefaultNameBuiltin;
        const exports = @import("../runtime_helper_modules.zig").catalogExports(.keep_names);
        if (exports.len != 2) return error.InvalidDefaultNameBuiltin;
        var found = false;
        for (provider.export_bindings, 0..) |binding, index| {
            // The immutable catalog export protocol selects this export row;
            // its actual local-node edge supplies the source SymbolId.
            if (!std.mem.eql(u8, binding.exported_name, exports[0])) continue;
            if (found) return error.InvalidDefaultNameBuiltin;
            const sid = provider.exportBindingLocalNodeSemanticIndex(binding) orelse return error.InvalidDefaultNameBuiltin;
            result = .{ .module_index = provider.index, .export_index = @intCast(index), .symbol_id = @fromBackingInt(sid), .owner_token = semantic.owner_token };
            found = true;
        }
        if (!found) return error.InvalidDefaultNameBuiltin;
    }
    return result;
}

pub fn exactNames(graph: anytype) !SymbolID {
    const known = graph.legacy_name_builtin orelse return error.InvalidDefaultNameBuiltin;
    const provider = graph.getModule(known.module_index) orelse return error.InvalidDefaultNameBuiltin;
    const origin = provider.runtime_helper_source orelse return error.InvalidDefaultNameBuiltin;
    const semantic = provider.semantic orelse return error.InvalidDefaultNameBuiltin;
    if (origin.catalog != .keep_names or semantic.owner_token == .unassigned or semantic.owner_token != known.owner_token or
        !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, provider.source) or
        known.export_index >= provider.export_bindings.len) return error.InvalidDefaultNameBuiltin;
    const binding = provider.export_bindings[known.export_index];
    const exports = @import("../runtime_helper_modules.zig").catalogExports(.keep_names);
    if (exports.len != 2 or !std.mem.eql(u8, binding.exported_name, exports[0]) or
        provider.exportBindingLocalNodeSemanticIndex(binding) != @backingInt(known.symbol_id)) return error.InvalidDefaultNameBuiltin;
    return SymbolID.make(provider.index, @backingInt(known.symbol_id));
}
