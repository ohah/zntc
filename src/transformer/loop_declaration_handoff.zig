//! Birth evidence for stable for-of declarations revisited by a generator.
//! Records live only for this Transformer invocation; no identity is inferred
//! from a generated spelling or reconstructed after the declaration moves.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub const Role = enum { normal_completion, did_error, error_value, iterator, step, loop_value };
pub const Birth = struct {
    source_owner: NodeIndex,
    source_scope: ScopeId,
    declaration: NodeIndex,
    declarator: NodeIndex,
    binding_node: ast_mod.Node,
    symbol_id: u32,
    storage_scope: ScopeId,
    origin_scope: ScopeId,
    role: Role,
    ordinal: u32,
    count: u32,
};
pub const Registry = std.AutoHashMapUnmanaged(u32, Birth);

pub fn record(self: anytype, source_owner: NodeIndex, source_scope: ScopeId, declaration: NodeIndex, roles: []const Role) !void {
    if (!self.semantic_edit_enabled) return;
    const source_origin: NodeIndex = @fromBackingInt(self.scope_owner_origins.get(@backingInt(source_owner)) orelse @backingInt(source_owner));
    if (self.scope_owner_map.get(@backingInt(source_origin)) != @as(?u32, @backingInt(source_scope)))
        @panic("stable for-of declaration lost its actual source owner");
    const owner = self.ast.getNode(source_origin);
    if (owner.tag != .for_of_statement) @panic("stable for-of declaration has a foreign source role");
    const node = self.ast.getNode(declaration);
    if (node.tag != .variable_declaration or self.ast.variableDeclarationKind(node) != .@"var")
        @panic("stable for-of producer did not create a var declaration");
    const start = self.ast.extra_data.items[node.data.extra + 1];
    const count = self.ast.extra_data.items[node.data.extra + 2];
    if (roles.len != count or count == 0) @panic("stable for-of declaration roles disagree with its actual bindings");
    const editor = &self.semantic_editor.?;
    for (0..count) |i| {
        const declarator: NodeIndex = @fromBackingInt(self.ast.extra_data.items[start + i]);
        const item = self.ast.getNode(declarator);
        if (item.tag != .variable_declarator) @panic("stable for-of producer has an invalid declarator");
        const binding: NodeIndex = @fromBackingInt(self.ast.extra_data.items[item.data.extra]);
        const payload = self.ast.getNode(binding);
        const id = self.getSymbolIdAt(binding) orelse @panic("stable for-of binding has no exact SID");
        if (payload.tag != .binding_identifier or id >= editor.symbols.items.len or
            @backingInt(binding) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(binding)] != id)
            @panic("stable for-of declaration changed its actual binding identity");
        if (roles[i] == .loop_value) {
            const source_left = self.ast.getNode(owner.data.ternary.a);
            if (source_left.tag != .variable_declaration or self.ast.variableDeclarationKind(source_left) != .@"var" or
                self.ast.extra_data.items[source_left.data.extra + 2] != 1)
                @panic("loop value birth has no source var header");
            const source_item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[self.ast.extra_data.items[source_left.data.extra + 1]]));
            if (source_item.tag != .variable_declarator or self.ast.extra_data.items[source_item.data.extra] != @backingInt(binding))
                @panic("loop value birth changed the actual source binding");
        }
        const symbol = editor.symbols.items[id];
        if (symbol.kind != .variable_var) @panic("stable for-of producer has a non-var storage role");
        const known: Birth = .{
            .source_owner = source_origin,
            .source_scope = source_scope,
            .declaration = declaration,
            .declarator = declarator,
            .binding_node = payload,
            .symbol_id = id,
            .storage_scope = symbol.scope_id,
            .origin_scope = symbol.origin_scope,
            .role = roles[i],
            .ordinal = @intCast(i),
            .count = count,
        };
        const slot = try self.loop_declaration_births.getOrPut(self.allocator, @backingInt(binding));
        if (slot.found_existing) @panic("stable for-of binding was born twice");
        slot.value_ptr.* = known;
    }
}

pub fn matches(self: anytype, declaration: NodeIndex) bool {
    if (!self.semantic_edit_enabled or declaration.isNone()) return false;
    const node = self.ast.getNode(declaration);
    if (node.tag != .variable_declaration or self.ast.variableDeclarationKind(node) != .@"var") return false;
    const count = self.ast.extra_data.items[node.data.extra + 2];
    const start = self.ast.extra_data.items[node.data.extra + 1];
    if (count == 0) return false;
    const editor = &self.semantic_editor.?;
    var first: ?Birth = null;
    for (0..count) |i| {
        const item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[start + i]));
        if (item.tag != .variable_declarator) return false;
        const binding: NodeIndex = @fromBackingInt(self.ast.extra_data.items[item.data.extra]);
        const known = self.loop_declaration_births.get(@backingInt(binding)) orelse return false;
        if (known.ordinal != i or known.count != count) return false;
        const role_matches = switch (known.role) {
            .normal_completion, .did_error, .error_value, .loop_value => count == 1 and i == 0,
            .iterator => count == 2 and i == 0,
            .step => count == 2 and i == 1,
        };
        if (!role_matches) return false;
        if (first) |previous| {
            if (known.declaration != previous.declaration or known.source_owner != previous.source_owner or known.source_scope != previous.source_scope)
                return false;
        } else first = known;
        if (self.scope_owner_map.get(@backingInt(known.source_owner)) != @as(?u32, @backingInt(known.source_scope))) return false;
        if (self.ast.getNode(known.source_owner).tag != .for_of_statement) return false;
        if (known.role == .loop_value) {
            const source_owner = self.ast.getNode(known.source_owner);
            const source_left = self.ast.getNode(source_owner.data.ternary.a);
            if (source_left.tag != .variable_declaration or self.ast.variableDeclarationKind(source_left) != .@"var" or
                self.ast.extra_data.items[source_left.data.extra + 2] != 1) return false;
            const source_item = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[self.ast.extra_data.items[source_left.data.extra + 1]]));
            if (source_item.tag != .variable_declarator or self.ast.extra_data.items[source_item.data.extra] != @backingInt(binding)) return false;
        }
        const original = self.ast.getNode(known.declarator);
        if (original.tag != .variable_declarator or self.ast.extra_data.items[original.data.extra] != @backingInt(binding)) return false;
        const actual = self.ast.getNode(binding);
        if (actual.tag != known.binding_node.tag or actual.span.start != known.binding_node.span.start or actual.span.end != known.binding_node.span.end or
            actual.data.string_ref.start != known.binding_node.data.string_ref.start or actual.data.string_ref.end != known.binding_node.data.string_ref.end)
            return false;
        if (self.getSymbolIdAt(binding) != known.symbol_id or @backingInt(binding) >= editor.symbol_ids.items.len or
            editor.symbol_ids.items[@backingInt(binding)] != known.symbol_id or known.symbol_id >= editor.symbols.items.len) return false;
        const symbol = editor.symbols.items[known.symbol_id];
        if (symbol.kind != .variable_var or symbol.scope_id != known.storage_scope or symbol.origin_scope != known.origin_scope) return false;
        var anchored = false;
        for (editor.references.items) |row| {
            if (!row.flags.declare or row.declaration_node_index != binding) continue;
            if (@backingInt(row.symbol_id) != known.symbol_id or row.scope_id != known.storage_scope) return false;
            anchored = true;
        }
        if (!anchored) return false;
    }
    return true;
}
