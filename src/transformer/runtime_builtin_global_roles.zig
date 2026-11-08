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

    pub fn globalName(role: Role) []const u8 {
        return switch (role) {
            .reference_error => "ReferenceError",
            .type_error => "TypeError",
            .object => "Object",
            .reflect => "Reflect",
        };
    }
};

pub fn collectRootSourceBindings(self: anytype, roles: []const Role, selected: *Table) !void {
    if (roles.len == 0 or self.scopes.len == 0 or self.scopes[0].blocksMangling()) return;
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
