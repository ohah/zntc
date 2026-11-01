//! Binding-only NormalForm evidence for registered runtime output declarations.
//! This does not authorize an AST reference or change public Exact/Strict rules.
const witness = @import("output_runtime_witness.zig");

pub const Proof = struct {
    target: witness.Target,
    context: witness.QueryContext,

    pub fn wrapper(self: Proof) ?witness.Wrapper {
        if (!self.target.validatesContext(self.context)) return null;
        return self.target.source.wrapper;
    }

    pub fn moduleIndex(self: Proof) ?@import("../bundler/types.zig").ModuleIndex {
        if (!self.target.validatesContext(self.context)) return null;
        return self.target.module.index;
    }

    /// Revalidate the complete actual target backing before consuming a role.
    /// A caller cannot turn a SID collection into output-origin authority.
    pub fn hasOutputBinding(self: Proof, sid: u32) bool {
        if (!self.target.validatesContext(self.context)) return false;
        for (self.target.source.entries) |entry| {
            if (@backingInt(entry.symbol) != sid) continue;
            if (self.context.retirements.contains(sid)) return false;
            return switch (entry.role) {
                .cjs_exports_parameter, .cjs_module_parameter => self.target.source.wrapper != null,
                .module_init, .module_exports, .module_require, .cjs_factory, .cjs_internal, .esm_factory, .esm_internal, .to_binary, .interop_helper, .interop_internal, .hmr_internal, .require_shim => noLexicalEdges(self.context, sid),
                _ => false,
            };
        }
        return false;
    }
};

pub fn prepare(target: witness.Target, context: witness.QueryContext) ?Proof {
    if (!target.validatesContext(context)) return null;
    const proof: Proof = .{ .target = target, .context = context };
    for (target.source.entries) |entry| {
        if (!proof.hasOutputBinding(@backingInt(entry.symbol))) return null;
    }
    return proof;
}

fn noLexicalEdges(context: witness.QueryContext, sid: u32) bool {
    if (sid >= context.symbols.len) return false;
    const symbol = context.symbols[sid];
    if (!symbol.scope_id.isNone() or !symbol.origin_scope.isNone() or
        symbol.reference_count != 0 or symbol.write_count != 0) return false;
    for (context.symbol_ids) |maybe| if (maybe == sid) return false;
    for (context.references) |row| if (@backingInt(row.symbol_id) == sid) return false;
    for (context.scope_maps) |map| {
        var values = map.valueIterator();
        while (values.next()) |value| if (value.* == sid) return false;
    }
    var helper_values = context.helper_scope_map.valueIterator();
    while (helper_values.next()) |value| if (value.* == sid) return false;
    inline for (.{ context.class_self_symbols, context.namespace_member_owners, context.namespace_declaration_owners }) |map| {
        var values = map.valueIterator();
        while (values.next()) |value| if (value.* == sid) return false;
    }
    inline for (.{ context.namespace_member_owners, context.namespace_declaration_owners }) |map| {
        var keys = map.keyIterator();
        while (keys.next()) |key| if (key.* == sid) return false;
    }
    return true;
}

/// Build a query using the actual target fields; consumer-supplied query arrays
/// must still be passed through prepare/validatesContext before delegation.
pub fn forTarget(target: witness.Target) ?Proof {
    const ast = if (target.module.ast) |*value| value else return null;
    const sem = if (target.module.semantic) |*value| value else return null;
    return prepare(target, .{
        .ast = ast,
        .symbols = sem.symbols.items,
        .symbol_ids = sem.symbol_ids,
        .scopes = sem.scopes,
        .scope_maps = sem.scope_maps,
        .scope_owners = &sem.scope_owner_map,
        .references = sem.references,
        .helper_scope_map = &sem.helper_scope_map,
        .helper_reference_nodes = if (target.module.transform_cache) |cache| cache.helper_ref_nodes else &.{},
        .scope_history = &sem.scope_history,
        .retirements = &sem.source_owned_retirements,
        .provenance = &sem.node_scope_provenance,
        .class_self_symbols = &sem.class_self_symbol_map,
        .namespace_member_owners = &sem.namespace_member_owners,
        .namespace_declaration_owners = &sem.namespace_declaration_owners,
    });
}
