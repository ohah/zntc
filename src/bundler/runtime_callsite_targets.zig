//! Validate exact producer-owned foreign callsite identities.
const SymbolID = @import("symbol.zig").SymbolID;

/// Validate an already selected typed foreign role. Neither its spelling nor
/// another same-kind row can replace a missing producer-owned identity.
pub fn validateTargetRole(graph: anytype, target: anytype) !void {
    const module = graph.getModule(target.symbol.module) orelse return error.InvalidCallsiteTarget;
    const expected: SymbolID = switch (target.role) {
        .schedule => try @import("runtime_dynamic_import_ast.zig").exactBinding(graph),
        .entry_guard => try @import("runtime_entry_guard_ast.zig").exactBinding(graph),
        .to_esm => blk: {
            const provider = graph.interop_ast_provider orelse return error.InvalidCallsiteTarget;
            const bindings = try @import("runtime_interop_ast.zig").resolveBindings(graph);
            break :blk SymbolID.make(provider.module_index, @backingInt(bindings[7].?.symbol_id));
        },
        .require => blk: {
            if (module.wrap_kind != .cjs) return error.InvalidCallsiteTarget;
            const id = module.require_symbol orelse return error.InvalidCallsiteTarget;
            const sem = module.semantic orelse return error.InvalidCallsiteTarget;
            if (@backingInt(id) >= sem.symbols.items.len or sem.symbols.items[@backingInt(id)].synthetic_kind != .cjs_require) return error.InvalidCallsiteTarget;
            break :blk SymbolID.make(module.index, @backingInt(id));
        },
        .esm_init => try module.esmInitSymbol(),
        .esm_namespace => try module.esmNamespaceSymbol(),
    };
    if (expected.module != target.symbol.module or expected.inner != target.symbol.inner) return error.InvalidCallsiteTarget;
}
