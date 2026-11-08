//! Globals read by compiler-owned raw helper output. A spelling identifies a
//! fixed builtin protocol role, never a source SymbolId. Source selections are
//! made from actual Symbol records and validated against their owner map.
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Table = @import("block_rename_table.zig").Table;

pub const Role = enum {
    reference_error,
    type_error,
    object,
    reflect,
    symbol,
    weak_map,

    pub fn globalName(role: Role) []const u8 {
        return switch (role) {
            .reference_error => "ReferenceError",
            .type_error => "TypeError",
            .object => "Object",
            .reflect => "Reflect",
            .symbol => "Symbol",
            .weak_map => "WeakMap",
        };
    }
};

pub fn collectRootSourceBindings(self: anytype, roles: []const Role, selected: *Table) !void {
    if (self.scopes.len == 0 or self.scopes[0].blocksMangling()) return;
    try inspectRootSourceBindings(self, roles, selected);
}

/// Read-only selection is also safe in dynamic scopes; callers must preserve
/// those source spellings and isolate their helper globals instead of renaming.
pub fn inspectRootSourceBindings(self: anytype, roles: []const Role, selected: *Table) !void {
    if (roles.len == 0 or self.scopes.len == 0) return;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const maps = if (self.semantic_editor) |*editor| editor.scope_maps.items else self.scope_maps;
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != null or symbol.scope_id.isNone()) continue;
        const owner = symbol.scope_id.toIndex();
        if (owner >= scopes.len or owner >= maps.len)
            @panic("runtime builtin source binding has no valid owner scope");
        const scope = scopes[owner];
        if (!scope.parent.isNone() or (scope.kind != .global and scope.kind != .module)) continue;
        const name = self.ast.getText(symbol.name);
        for (roles) |role| {
            if (!Scanner.identifierValueEquals(name, role.globalName())) continue;
            var found = false;
            var bindings = maps[owner].iterator();
            while (bindings.next()) |binding| {
                if (binding.value_ptr.* != sid) continue;
                if (!Scanner.identifierValueEquals(binding.key_ptr.*, role.globalName()))
                    @panic("runtime builtin source binding changed its exact owner map");
                found = true;
            }
            if (!found) @panic("runtime builtin source binding has no exact owner map row");
            try selected.put(self.allocator, @intCast(sid), {});
        }
    }
}

/// Only actual private PutValue syntax demands the field-set helper's captured
/// WeakMap role. Private reads and ordinary source spellings do not activate it.
pub fn hasPrivateWrite(self: anytype, root: @import("../parser/ast.zig").NodeIndex) !bool {
    const std = @import("std");
    const ast = @import("../parser/ast.zig");
    const Pending = struct { node: ast.NodeIndex, write: bool };
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(ast.NodeIndex, u8) = .empty;
    defer seen.deinit(self.allocator);
    try pending.append(self.allocator, .{ .node = root, .write = false });
    while (pending.pop()) |item| {
        if (item.node.isNone()) continue;
        const bit: u8 = if (item.write) 2 else 1;
        const slot = try seen.getOrPut(self.allocator, item.node);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        if (slot.value_ptr.* & bit != 0) continue;
        slot.value_ptr.* |= bit;
        const node = self.ast.getNode(item.node);
        if (item.write and node.tag == .private_field_expression) return true;
        switch (node.tag) {
            .assignment_expression => {
                try pending.append(self.allocator, .{ .node = node.data.binary.left, .write = true });
                try pending.append(self.allocator, .{ .node = node.data.binary.right, .write = false });
            },
            .assignment_pattern, .assignment_target_with_default => {
                try pending.append(self.allocator, .{ .node = node.data.binary.left, .write = item.write });
                try pending.append(self.allocator, .{ .node = node.data.binary.right, .write = false });
            },
            .assignment_target_property_property => {
                try pending.append(self.allocator, .{ .node = node.data.binary.left, .write = false });
                try pending.append(self.allocator, .{ .node = node.data.binary.right, .write = item.write });
            },
            .array_assignment_target, .object_assignment_target => {
                var children = @import("../parser/ast_walk.zig").children(self.ast, node);
                while (children.next()) |child| try pending.append(self.allocator, .{ .node = child, .write = item.write });
            },
            .assignment_target_rest, .parenthesized_expression => try pending.append(self.allocator, .{ .node = node.data.unary.operand, .write = item.write }),
            .update_expression => try pending.append(self.allocator, .{ .node = self.ast.readExtraNode(node.data.extra, 0), .write = true }),
            .for_of_statement, .for_in_statement => {
                try pending.append(self.allocator, .{ .node = self.ast.readExtraNode(node.data.extra, 0), .write = true });
                try pending.append(self.allocator, .{ .node = self.ast.readExtraNode(node.data.extra, 1), .write = false });
                try pending.append(self.allocator, .{ .node = self.ast.readExtraNode(node.data.extra, 2), .write = false });
            },
            else => {
                var children = @import("../parser/ast_walk.zig").children(self.ast, node);
                while (children.next()) |child| try pending.append(self.allocator, .{ .node = child, .write = false });
            },
        }
    }
    return false;
}
