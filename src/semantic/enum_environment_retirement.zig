//! Birth authority for an erased const enum's analyzer-owned runtime frame.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Symbol = @import("symbol.zig");
const History = @import("scope_frame_history.zig");
const Retirement = @import("source_owned_retirement.zig");

pub const Member = struct {
    declaration: Ast.NodeIndex,
    declaration_node: Ast.Node,
    key: Ast.NodeIndex,
    key_node: Ast.Node,
    read_node: Ast.Node,
};

pub const Witness = struct {
    owner: History.Owner,
    parameter_symbol: Symbol.SymbolId,
    binding_declaration: Symbol.Reference,
    binding_node: Ast.Node,
    member: ?Member = null,
};

pub fn validate(a: std.mem.Allocator, w: Retirement.Witness, state: *const Retirement.Map, tree: *const Ast.Ast, live: *const std.DynamicBitSet, rows: []const Symbol.Symbol, ids: []const ?u32, scopes: []const @import("scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), maybe_history: ?*const History.History) std.mem.Allocator.Error!bool {
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
    if (before.kind != .parameter or !std.meta.eql(before.decl_flags, Symbol.SymbolKind.parameter.declFlags()) or before.scope_id != w.source_scope or before.origin_scope != w.source_scope or before.isExported() or
        w.declaration_node != null or w.declaration.symbol_id != w.symbol_id or !w.declaration.declaration_node_index.isNone()) return false;
    if (before.synthetic_kind != .enum_iife_member and
        (!w.declaration.node_index.isNone() or w.declaration.scope_id != w.source_scope or
            !std.meta.eql(w.declaration.flags, @as(Symbol.ReferenceFlags, .{ .declare = true })))) return false;
    if ((before.synthetic_kind == .enum_iife_member) != (birth.member != null)) return false;
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
    } else if (before.synthetic_kind == .enum_iife_member) {
        const member = birth.member orelse return false;
        if (!validRetiredOwner(w, state) or before.output_name_hint.len != 0 or member.declaration.isNone() or member.key.isNone() or
            @backingInt(member.declaration) >= tree.nodes.items.len or @backingInt(member.key) >= tree.nodes.items.len or
            member.declaration_node.tag != .ts_enum_member or tree.getNode(member.declaration).tag != .ts_enum_member or
            !std.meta.eql(tree.getNode(member.declaration).span, member.declaration_node.span) or
            !std.meta.eql(tree.getNode(member.declaration).data.binary, member.declaration_node.data.binary) or
            member.declaration_node.data.binary.left != member.key or !std.meta.eql(before.name, member.key_node.span) or
            !std.meta.eql(before.declaration_span, member.key_node.span) or !sameLeaf(tree.getNode(member.key), member.key_node) or
            w.declaration.node_index.isNone() or @backingInt(w.declaration.node_index) >= tree.nodes.items.len or
            live.isSet(@backingInt(w.declaration.node_index)) or w.declaration.flags.declare or
            !sameLeaf(tree.getNode(w.declaration.node_index), member.read_node)) return false;
        const read = member.read_node;
        if ((read.tag != .identifier_reference and read.tag != .assignment_target_identifier) or
            !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(tree.identifierNameText(read), before.synthetic_name)) return false;
        var found = false;
        var read_found = false;
        const start = tree.readExtra(w.source_owner_node.data.extra, Ast.EnumExtra.members_start);
        const len = tree.readExtra(w.source_owner_node.data.extra, Ast.EnumExtra.members_len);
        if (start > tree.extra_data.items.len or len > tree.extra_data.items.len - start) return false;
        for (tree.extra_data.items[start..][0..len]) |raw| {
            if (raw >= tree.nodes.items.len) return false;
            const item = tree.nodes.items[raw];
            if (raw == @backingInt(member.declaration)) {
                if (found) return false;
                found = true;
            }
            if (item.tag != .ts_enum_member or item.data.binary.right.isNone()) continue;
            const references = try @import("reference_walk.zig").collectIdentifierReferences(a, tree, item.data.binary.right);
            defer a.free(references);
            if (std.mem.indexOfScalar(Ast.NodeIndex, references, w.declaration.node_index) == null) continue;
            if (read_found) return false;
            read_found = true;
            var parents = try @import("../transformer/symbol_coverage.zig").collectParentTraces(a, tree, item.data.binary.right);
            defer parents.deinit(a);
            var expected_flags: Symbol.ReferenceFlags = if (read.tag == .assignment_target_identifier) .{ .write = true } else .{ .read = true };
            if (parents.get(@backingInt(w.declaration.node_index))) |parent| {
                if (parent.ambiguous or parent.parent >= tree.nodes.items.len) return false;
                const parent_node = tree.nodes.items[parent.parent];
                if (parent_node.tag == .update_expression and parent_node.data.unary.operand == w.declaration.node_index) {
                    expected_flags = .{ .read = true, .write = true };
                } else if (parent_node.tag == .assignment_expression and parent_node.data.binary.left == w.declaration.node_index) {
                    const op: @import("../lexer/token.zig").Kind = @fromBackingInt(@intCast(parent_node.data.binary.flags));
                    expected_flags = .{ .read = op.isCompoundAssignment(), .write = true };
                }
            }
            if (!std.meta.eql(expected_flags, w.declaration.flags)) return false;
        }
        if (!found or !read_found) return false;
        switch (member.key_node.tag) {
            .binding_identifier, .identifier_reference => if (!@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(tree.identifierNameText(member.key_node), before.synthetic_name)) return false,
            .string_literal => {
                const value = (try tree.staticKeyName(a, member.key)) orelse return false;
                defer a.free(value);
                if (!std.mem.eql(u8, value, before.synthetic_name)) return false;
            },
            else => return false,
        }
        var scope = w.declaration.scope_id;
        var fuel = scopes.len + 1;
        while (!scope.isNone() and scope != w.source_scope and fuel > 0) : (fuel -= 1) {
            if (scope.toIndex() >= scopes.len) return false;
            scope = scopes[scope.toIndex()].parent;
        }
        if (scope != w.source_scope) return false;
    } else return false;
    var expected = before;
    expected.reference_count = 0;
    expected.write_count = 0;
    return Retirement.equalSymbol(expected, rows[sid]);
}

fn sameLeaf(left: Ast.Node, right: Ast.Node) bool {
    if (left.tag != right.tag or !std.meta.eql(left.span, right.span)) return false;
    return switch (left.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier, .string_literal => std.meta.eql(left.data.string_ref, right.data.string_ref),
        else => false,
    };
}

pub fn validRetiredOwner(w: Retirement.Witness, state: *const Retirement.Map) bool {
    if (w.reason != .erased_const_enum_environment or w.before.synthetic_kind != .enum_iife_member) return false;
    const birth = w.enum_environment orelse return false;
    if (birth.member == null or w.before.synthetic_owner_id != birth.parameter_symbol) return false;
    const parameter = state.get(@backingInt(birth.parameter_symbol)) orelse return false;
    return parameter.reason == .erased_const_enum_environment and parameter.before.synthetic_kind == .enum_iife_parameter and
        parameter.source_scope == w.source_scope and parameter.source_owner == w.source_owner and
        parameter.source_name == w.source_name and parameter.source_name_symbol == w.source_name_symbol;
}
