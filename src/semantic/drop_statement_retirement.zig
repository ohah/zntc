//! Retirement authority from an actual explicit statement-drop producer.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Symbol = @import("symbol.zig");
const History = @import("scope_frame_history.zig");
const Retirement = @import("source_owned_retirement.zig");

pub const Witness = struct {
    statement: u32,
    scope_owner: ?u32,
};

pub fn containsNode(history: *const History.History, statement: u32, node: Ast.NodeIndex) bool {
    if (statement >= history.source_dropped_statements.len) return false;
    const root = history.source_dropped_statements[statement];
    if (root.source.index == node) return true;
    if (root.edge_start > history.source_drop_edges.len or root.edge_len > history.source_drop_edges.len - root.edge_start) return false;
    for (history.source_drop_edges[root.edge_start..][0..root.edge_len]) |edge| {
        if (edge.parent.index == node) return true;
        if (edge.child) |child| if (child.index == node) return true;
    }
    return false;
}

pub fn validate(w: Retirement.Witness, tree: *const Ast.Ast, live: *const std.DynamicBitSet, rows: []const Symbol.Symbol, ids: []const ?u32, scopes: []const @import("scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), index: *const History.Index) bool {
    const birth = w.dropped_statement orelse return false;
    if (!index.valid or birth.statement >= index.history.source_dropped_statements.len or @backingInt(w.symbol_id) >= rows.len or
        w.source_scope.isNone() or w.source_scope.toIndex() >= scopes.len or w.before.scope_id != w.source_scope or w.before.origin_scope != w.source_scope or
        w.erased_import != null or w.static_capture_alias != null or w.function_name_elision != null or w.enum_environment != null) return false;
    const root = index.history.source_dropped_statements[birth.statement];
    if (root.source.index != w.source_owner or w.source_owner.isNone() or live.isSet(@backingInt(w.source_owner))) return false;
    const owner_node = tree.getNode(w.source_owner);
    const width = owner_node.tag.dataWidth();
    if (owner_node.tag != w.source_owner_node.tag or !std.meta.eql(owner_node.span, w.source_owner_node.span) or
        !std.mem.eql(u8, std.mem.asBytes(&owner_node.data)[0..width], std.mem.asBytes(&w.source_owner_node.data)[0..width])) return false;
    const source_frame = index.frameAt(w.source_scope, root.entry_epoch) orelse return false;
    if (source_frame.parent != w.source_parent) return false;
    if (birth.scope_owner) |owner_index| {
        if (owner_index >= index.history.source_owners.len) return false;
        const owner = index.history.source_owners[owner_index];
        if (owner.scope != w.source_scope or !containsNode(index.history, birth.statement, owner.owner.node) or
            owners.contains(@backingInt(owner.owner.node)) or w.closure_scope != w.source_scope or w.closure_parent != w.source_parent) return false;
        const current = History.Owner.capture(tree, owner.owner.node) catch return false;
        if (current == null or !std.meta.eql(current.?, owner.owner)) return false;
    } else if (!w.closure_scope.isNone() or !w.closure_parent.isNone()) return false;
    const row = w.declaration;
    if (row.symbol_id != w.symbol_id or row.scope_id != w.source_scope or !row.node_index.isNone() or
        !std.meta.eql(row.flags, @as(Symbol.ReferenceFlags, .{ .declare = true }))) return false;
    if (w.declaration_node) |binding| {
        if (w.source_name.isNone() or @backingInt(w.source_name) >= ids.len or w.source_name_symbol != w.symbol_id or
            row.declaration_node_index != w.source_name or binding.tag != .binding_identifier or
            !containsNode(index.history, birth.statement, w.source_name) or
            !@import("source_drop_registry.zig").hasSourceBinding(index.history.source_drop_edges[root.edge_start..][0..root.edge_len], w.source_name, @backingInt(w.symbol_id)) or live.isSet(@backingInt(w.source_name)) or
            !@import("import_erasure.zig").equalNode(tree.getNode(w.source_name), binding) or
            !std.meta.eql(w.before.name, binding.span) or w.before.declaration_span.start < root.source.span.start or
            w.before.declaration_span.end > root.source.span.end or w.before.isSynthetic() or w.before.synthetic_owner_id != null or
            !w.before.parameter_copy.parameter_source.isNone() or !w.before.annex_b_alias.variable.isNone()) return false;
    } else {
        const owner_index = birth.scope_owner orelse return false;
        const owner = index.history.source_owners[owner_index];
        if (!w.source_name.isNone() or !w.source_name_symbol.isNone() or !row.declaration_node_index.isNone() or
            w.before.synthetic_kind != .implicit_arguments or w.before.kind != .parameter or
            !std.meta.eql(w.before.decl_flags, Symbol.SymbolKind.parameter.declFlags()) or w.before.synthetic_owner_id != null or
            !std.mem.eql(u8, w.before.synthetic_name, "arguments") or w.before.output_name_hint.len != 0 or
            !std.meta.eql(w.before.declaration_span, owner.owner.span) or
            (owner.owner.tag != .function_declaration and owner.owner.tag != .function_expression)) return false;
    }
    var expected = w.before;
    expected.reference_count = 0;
    expected.write_count = 0;
    return Retirement.equalSymbol(expected, rows[@backingInt(w.symbol_id)]);
}
