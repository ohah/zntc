//! Exact witness for a scalar local ESM export in a const-only provider.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Module = @import("module.zig").Module;
const SymbolID = @import("symbol.zig").SymbolID;

pub const Witness = struct {
    symbol: SymbolID,
    local_symbol_node: ast_mod.NodeIndex,
    exported_name: []const u8,
};

/// Resolve one named export only when the provider is a top-level list of
/// scalar `export const` declarations. Other exports remain independent live
/// candidates for the tree shaker; this witness grants authority to just one.
pub fn resolveName(module: *const Module, requested_name: []const u8) ?Witness {
    return resolve(module, .{ .name = requested_name });
}

/// Resolve the exported name belonging to one exact provider SymbolId.
pub fn resolveSymbol(module: *const Module, requested_symbol: u32) ?Witness {
    return resolve(module, .{ .symbol = requested_symbol });
}

const Request = union(enum) { name: []const u8, symbol: u32 };

fn resolve(module: *const Module, request: Request) ?Witness {
    const export_count = module.export_bindings.len;
    if (module.wrap_kind != .none or module.import_bindings.len != 0 or module.import_records.len != 0 or
        export_count == 0 or module.dynamic_imports.items.len != 0 or module.transform_cache != null or
        module.parse_arena == null) return null;
    const ast = if (module.ast) |*value| value else return null;
    const sem = if (module.semantic) |*value| value else return null;
    if (ast.nodes.items.len == 0 or ast.transformed_root != null or ast.transform_boundary != null or ast.is_typescript or
        ast.has_jsx or ast.has_decorator or sem.scopes.len != 1 or sem.symbols.items.len != export_count or
        sem.runtime_identities != null or sem.strict_output_context.functions.len != 0 or sem.scope_maps.len != 1 or
        sem.references.len != sem.symbols.items.len) return null;
    for (sem.scopes) |scope| if (scope.blocksMangling()) return null;

    const root: ast_mod.NodeIndex = @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const root_node = ast.getNode(root);
    if (root_node.tag != .program or root_node.data.list.len != export_count or
        root_node.data.list.start > ast.extra_data.items.len or
        root_node.data.list.len > ast.extra_data.items.len - root_node.data.list.start) return null;
    const root_scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(sem.scope_owner_map.get(@backingInt(root)) orelse return null);
    if (root_scope.isNone() or root_scope.toIndex() != 0 or sem.scopes[0].kind != .module or
        !sem.scopes[0].parent.isNone() or sem.scope_owner_map.count() != 1 or
        sem.scope_maps[0].count() != sem.symbols.items.len) return null;

    for (sem.symbols.items, 0..) |symbol, sid| {
        if (symbol.kind != .variable_const or symbol.scope_id != root_scope or
            sem.scope_maps[0].get(ast.getText(symbol.name)) != @as(?usize, sid)) return null;
    }
    for (sem.references) |reference| {
        const anchor = reference.declaration_node_index;
        if (!std.meta.eql(reference.flags, @import("../semantic/symbol.zig").ReferenceFlags{ .declare = true }) or
            !reference.node_index.isNone() or reference.scope_id != root_scope or reference.symbol_id.isNone() or
            @backingInt(reference.symbol_id) >= sem.symbols.items.len or anchor.isNone() or
            @backingInt(anchor) >= ast.nodes.items.len or @backingInt(anchor) >= sem.symbol_ids.len or
            ast.nodes.items[@backingInt(anchor)].tag != .binding_identifier or
            sem.symbol_ids[@backingInt(anchor)] != @as(?u32, @backingInt(reference.symbol_id))) return null;
    }

    var selected: ?@TypeOf(module.export_bindings[0]) = null;
    for (module.export_bindings) |exported| {
        if (exported.kind != .local or exported.import_record_index != null or exported.public_key_origin != null or
            exported.public_key_literal != null or exported.public_key_binding_value != null or exported.has_public_key_literal or
            exported.default_export_node != null or exported.has_default_export_facade or exported.declared_via_pattern or
            exported.init_is_fn_or_class or !std.mem.eql(u8, exported.exported_name, exported.local_name)) return null;
        const matches = switch (request) {
            .name => |name| std.mem.eql(u8, exported.exported_name, name),
            .symbol => |sid| if (exported.local_symbol_node) |anchor| blk: {
                if (@backingInt(anchor) >= sem.symbol_ids.len) break :blk false;
                break :blk sem.symbol_ids[@backingInt(anchor)] == @as(?u32, sid);
            } else false,
        };
        if (!matches) continue;
        if (selected != null) return null;
        selected = exported;
    }
    const exported = selected orelse return null;
    const anchor = exported.local_symbol_node orelse return null;
    if (anchor.isNone() or @backingInt(anchor) >= sem.symbol_ids.len) return null;
    const sid = sem.symbol_ids[@backingInt(anchor)] orelse return null;
    if (sid >= sem.symbols.items.len or sem.symbols.items[sid].kind != .variable_const or
        sem.symbols.items[sid].scope_id != root_scope or
        sem.scope_maps[0].get(ast.getText(sem.symbols.items[sid].name)) != @as(?usize, sid)) return null;

    var declaration_count: usize = 0;
    for (sem.references) |reference| {
        if (@backingInt(reference.symbol_id) != sid) continue;
        if (!reference.flags.declare or reference.declaration_node_index != anchor or reference.scope_id != root_scope) return null;
        declaration_count += 1;
    }
    if (declaration_count != 1) return null;

    var anchor_occurrences: usize = 0;
    const top_level = ast.extra_data.items[root_node.data.list.start..][0..root_node.data.list.len];
    if (top_level.len != module.export_bindings.len) return null;
    for (top_level, 0..) |raw, export_index| {
        if (raw >= ast.nodes.items.len) return null;
        const statement = ast.nodes.items[raw];
        if (statement.tag != .export_named_declaration or statement.data.extra > ast.extra_data.items.len or
            ast.extra_data.items.len - statement.data.extra < 5) return null;
        const declaration_raw = ast.extra_data.items[statement.data.extra];
        if (declaration_raw >= ast.nodes.items.len) return null;
        const declaration = ast.nodes.items[declaration_raw];
        if (declaration.tag != .variable_declaration or !ast.hasExtra(declaration.data.extra, 2) or
            ast.extra_data.items[declaration.data.extra] != @backingInt(ast_mod.VariableDeclarationKind.@"const") or
            ast.extra_data.items[declaration.data.extra + 2] != 1) return null;
        const declarations_start = ast.extra_data.items[declaration.data.extra + 1];
        if (declarations_start >= ast.extra_data.items.len) return null;
        const declarator_raw = ast.extra_data.items[declarations_start];
        if (declarator_raw >= ast.nodes.items.len) return null;
        const declarator = ast.nodes.items[declarator_raw];
        if (declarator.tag != .variable_declarator or !ast.hasExtra(declarator.data.extra, 2)) return null;
        const local_raw = ast.extra_data.items[declarator.data.extra];
        if (local_raw >= sem.symbol_ids.len or ast.extra_data.items[declarator.data.extra + 1] != @backingInt(ast_mod.NodeIndex.none)) return null;
        const local_sid = sem.symbol_ids[local_raw] orelse return null;
        if (local_sid >= sem.symbols.items.len or sem.symbols.items[local_sid].kind != .variable_const or
            sem.symbols.items[local_sid].scope_id != root_scope) return null;
        const exported_binding = module.export_bindings[export_index];
        const local_node: ast_mod.NodeIndex = @fromBackingInt(@as(u32, @intCast(local_raw)));
        if (exported_binding.local_symbol_node == null or exported_binding.local_symbol_node.? != local_node or
            !std.mem.eql(u8, exported_binding.local_name, ast.getText(ast.getNode(local_node).span))) return null;
        const initializer = ast.extra_data.items[declarator.data.extra + 2];
        if (initializer >= ast.nodes.items.len) return null;
        switch (ast.nodes.items[initializer].tag) {
            .numeric_literal, .string_literal, .boolean_literal, .null_literal => {},
            else => return null,
        }
        if (local_raw == @backingInt(anchor)) anchor_occurrences += 1;
    }
    if (anchor_occurrences != 1) return null;
    return .{ .symbol = SymbolID.make(module.index, sid), .local_symbol_node = anchor, .exported_name = exported.exported_name };
}
