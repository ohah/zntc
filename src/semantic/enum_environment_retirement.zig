//! Birth authority for an erased const enum's analyzer-owned runtime frame.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Symbol = @import("symbol.zig");
const History = @import("scope_frame_history.zig");
const Retirement = @import("source_owned_retirement.zig");

pub const Witness = struct {
    owner: History.Owner,
    parameter_symbol: Symbol.SymbolId,
    binding_declaration: Symbol.Reference,
    binding_node: Ast.Node,
};

pub fn validate(w: Retirement.Witness, state: *const Retirement.Map, tree: *const Ast.Ast, live: *const std.DynamicBitSet, rows: []const Symbol.Symbol, ids: []const ?u32, scopes: []const @import("scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), maybe_history: ?*const History.History) bool {
    const birth = w.enum_environment orelse return false;
    const history = maybe_history orelse return false;
    const sid = @backingInt(w.symbol_id);
    if (sid >= rows.len or w.source_scope.isNone() or w.source_scope.toIndex() >= scopes.len or
        w.source_owner.isNone() or @backingInt(w.source_owner) >= tree.nodes.items.len or
        w.source_name.isNone() or @backingInt(w.source_name) >= ids.len or
        w.source_scope != w.closure_scope or w.source_parent != w.closure_parent or
        scopes[w.source_scope.toIndex()].parent != w.source_parent or
        scopes[w.source_scope.toIndex()].kind != .function or scopes[w.source_scope.toIndex()].blocksMangling() or
        owners.contains(@backingInt(w.source_owner)) or live.isSet(@backingInt(w.source_owner)) or live.isSet(@backingInt(w.source_name)) or
        w.erased_import != null or w.static_capture_alias != null or w.function_name_elision != null) return false;
    const outer = state.get(@backingInt(w.source_name_symbol)) orelse return false;
    if (outer.reason != .erased_const_enum_binding or outer.source_scope != w.source_parent or w.source_owner_node.tag != .ts_enum_declaration or
        tree.getNode(w.source_owner).tag != w.source_owner_node.tag or
        !std.meta.eql(tree.getNode(w.source_owner).span, w.source_owner_node.span) or
        tree.getNode(w.source_owner).data.extra != w.source_owner_node.data.extra or
        !tree.hasExtra(w.source_owner_node.data.extra, Ast.EnumExtra.flags) or
        tree.readExtra(w.source_owner_node.data.extra, Ast.EnumExtra.flags) != 1 or
        tree.readExtraNode(w.source_owner_node.data.extra, Ast.EnumExtra.name) != w.source_name or
        birth.binding_declaration.symbol_id != w.source_name_symbol or birth.binding_declaration.scope_id != w.source_parent or
        !birth.binding_declaration.node_index.isNone() or birth.binding_declaration.declaration_node_index != w.source_name or
        !std.meta.eql(birth.binding_declaration.flags, @as(Symbol.ReferenceFlags, .{ .declare = true })) or
        birth.binding_node.tag != .binding_identifier or
        !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(tree.getText(outer.before.name), tree.identifierNameText(birth.binding_node)) or
        !@import("import_erasure.zig").equalNode(tree.getNode(w.source_name), birth.binding_node)) return false;
    const current_owner = History.Owner.capture(tree, w.source_owner) catch return false;
    if (current_owner == null or !std.meta.eql(current_owner.?, birth.owner)) return false;
    var source_owner_found = false;
    for (history.source_owners) |source| if (source.scope == w.source_scope and std.meta.eql(source.owner, birth.owner)) {
        if (source_owner_found) return false;
        source_owner_found = true;
    };
    if (!source_owner_found or w.source_scope.toIndex() >= history.source_scopes.len or
        !History.sameFrame(history.source_scopes[w.source_scope.toIndex()], scopes[w.source_scope.toIndex()])) return false;
    const before = w.before;
    if (before.kind != .parameter or before.scope_id != w.source_scope or before.origin_scope != w.source_scope or before.isExported() or
        w.declaration_node != null or !w.declaration.node_index.isNone() or !w.declaration.declaration_node_index.isNone() or
        w.declaration.symbol_id != w.symbol_id or w.declaration.scope_id != w.source_scope or
        !std.meta.eql(w.declaration.flags, @as(Symbol.ReferenceFlags, .{ .declare = true }))) return false;
    if (before.synthetic_kind == .enum_iife_parameter) {
        if (birth.parameter_symbol != w.symbol_id or before.synthetic_owner_id != null or
            !std.mem.eql(u8, before.synthetic_name, before.output_name_hint) or before.synthetic_name.len == 0 or
            !std.meta.eql(before.name, tree.getNode(w.source_name).span) or
            !std.meta.eql(before.declaration_span, w.source_owner_node.span)) return false;
    } else if (before.synthetic_kind == .implicit_arguments) {
        const parameter = state.get(@backingInt(birth.parameter_symbol)) orelse return false;
        if (parameter.reason != .erased_const_enum_environment or parameter.before.synthetic_kind != .enum_iife_parameter or
            parameter.source_scope != w.source_scope or parameter.source_owner != w.source_owner or
            !std.mem.eql(u8, before.synthetic_name, "arguments") or before.output_name_hint.len != 0 or before.synthetic_owner_id != null or
            !std.meta.eql(before.declaration_span, w.source_owner_node.span)) return false;
    } else return false;
    var expected = before;
    expected.reference_count = 0;
    expected.write_count = 0;
    return Retirement.equalSymbol(expected, rows[sid]);
}
