//! Validate exact producer-owned foreign callsite identities.
const SymbolID = @import("symbol.zig").SymbolID;

/// Validate an already selected typed foreign role. Neither its spelling nor
/// another same-kind row can replace a missing producer-owned identity.
pub fn validateTargetRole(graph: anytype, target: anytype) !void {
    const module = graph.getModule(target.symbol.module) orelse return error.InvalidCallsiteTarget;
    const expected: SymbolID = switch (target.role) {
        .readiness_all => blk: {
            const helper = graph.tla_readiness_all orelse return error.InvalidCallsiteTarget;
            if (helper.owner_token != target.owner or helper.module_index != target.symbol.module) return error.InvalidCallsiteTarget;
            const origin = module.runtime_helper_source orelse return error.InvalidCallsiteTarget;
            if (origin.catalog != .readiness_all or !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, module.source)) return error.InvalidCallsiteTarget;
            break :blk SymbolID.make(helper.module_index, @backingInt(helper.symbol_id));
        },
        .keep_names_helper => blk: {
            const known = graph.legacy_name_builtin orelse return error.InvalidCallsiteTarget;
            if (known.owner_token != target.owner) return error.InvalidCallsiteTarget;
            break :blk try @import("lexical_initialization_builtin.zig").exactNames(graph);
        },
        .tdz_helper => blk: {
            const known = graph.lexical_tdz_builtin orelse return error.InvalidCallsiteTarget;
            if (known.owner_token != target.owner) return error.InvalidCallsiteTarget;
            break :blk try @import("lexical_initialization_builtin.zig").exact(graph);
        },
        .lexical_initialization_flag => blk: {
            const semantic = module.semantic orelse return error.InvalidCallsiteTarget;
            if (semantic.owner_token == .unassigned or semantic.owner_token != target.owner) return error.InvalidCallsiteTarget;
            const raw = @backingInt(target.symbol.inner);
            if (raw >= semantic.symbols.items.len) return error.InvalidCallsiteTarget;
            const flag = semantic.symbols.items[raw];
            const owner = flag.synthetic_owner_id orelse return error.InvalidCallsiteTarget;
            if (flag.synthetic_kind != .lexical_initialization_flag or
                !@import("../semantic/lexical_initialization.zig").validatePair(semantic.symbols.items, semantic.scopes, @backingInt(owner)) or
                semantic.symbols.items[@backingInt(owner)].lexical_initialization.flag != target.symbol.inner)
                return error.InvalidCallsiteTarget;
            break :blk target.symbol;
        },
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
        .namespace_export_value => blk: {
            const witness = @import("namespace_export_witness.zig").resolveSymbol(module, @backingInt(target.symbol.inner)) orelse return error.InvalidCallsiteTarget;
            break :blk witness.symbol;
        },
    };
    if (expected.module != target.symbol.module or expected.inner != target.symbol.inner) return error.InvalidCallsiteTarget;
}
