//! Position publication for native engine identities recorded at creation.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Context = @import("../semantic/statement_coordinates.zig").Context;

/// A native producer must not overwrite a source arguments binding. This is
/// a collision check only; the reference creator selects IDs by typed role.
pub fn hasAvailableEngineSlot(self: anytype, scope: ScopeId) bool {
    if (!self.semantic_edit_enabled) return true;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const maps = if (self.semantic_editor) |*editor| editor.scope_maps.items else self.scope_maps;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    if (scope.isNone() or scope.toIndex() >= scopes.len or scope.toIndex() >= maps.len or
        scopes[scope.toIndex()].kind != .function) return false;
    const existing = maps[scope.toIndex()].get("arguments") orelse return true;
    return existing < symbols.len and symbols[existing].scope_id == scope and
        symbols[existing].kind == .parameter and symbols[existing].synthetic_kind == .implicit_arguments;
}

pub fn record(self: anytype, id: SymbolId, scope: ScopeId) !void {
    const slot = try self.native_arguments_declaration_origins.getOrPut(self.allocator, @backingInt(id));
    if (slot.found_existing and slot.value_ptr.* != scope)
        @panic("native engine changed its creation scope");
    slot.value_ptr.* = scope;
}

pub fn publish(self: anytype, root: ast.NodeIndex) !void {
    if (!self.semantic_edit_enabled or self.native_arguments_declaration_origins.count() == 0) return;
    const editor = &self.semantic_editor.?;
    const coordinates = @import("../semantic/statement_coordinates.zig").collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("native arguments have invalid statement ownership: {s}", .{@errorName(err)}),
    };
    defer self.allocator.free(coordinates);
    var wanted: std.AutoHashMapUnmanaged(ScopeId, void) = .empty;
    defer wanted.deinit(self.allocator);
    var origins = self.native_arguments_declaration_origins.iterator();
    while (origins.next()) |entry| {
        const id = entry.key_ptr.*;
        const scope = entry.value_ptr.*;
        if (id >= editor.symbols.items.len or editor.symbols.items[id].scope_id != scope or
            editor.symbols.items[id].kind != .parameter or editor.symbols.items[id].synthetic_kind != .implicit_arguments)
            @panic("native engine lost its exact creation role");
        try wanted.put(self.allocator, scope, {});
    }
    var owners: std.AutoHashMapUnmanaged(ScopeId, Context) = .empty;
    defer owners.deinit(self.allocator);
    for (coordinates, 0..) |maybe_context, raw| {
        const context = maybe_context orelse continue;
        switch (self.ast.nodes.items[raw].tag) {
            .function, .function_expression, .function_declaration, .method_definition, .ts_module_declaration, .ts_enum_declaration => {},
            else => continue,
        }
        const scope = self.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(raw)))) orelse continue;
        if (!wanted.contains(scope)) continue;
        const slot = try owners.getOrPut(self.allocator, scope);
        if (slot.found_existing) @panic("native engine has multiple current function owners");
        slot.value_ptr.* = context;
    }
    var declarations: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer declarations.deinit(self.allocator);
    for (editor.references.items) |*row| {
        const id = @backingInt(row.symbol_id);
        const scope = self.native_arguments_declaration_origins.get(id) orelse continue;
        if (row.flags.declare) {
            if (row.scope_id != scope or !row.node_index.isNone() or !row.declaration_node_index.isNone() or
                !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })))
                @panic("native engine declaration changed its creation identity");
            const slot = try declarations.getOrPut(self.allocator, id);
            if (slot.found_existing) @panic("native engine has duplicate declarations");
            const context = owners.get(scope) orelse @panic("native engine has no actual function owner");
            row.stmt_idx = context.stmt_idx;
            row.scope_stmt_idx = context.scope_stmt_idx;
        } else if (!row.node_index.isNone() and @backingInt(row.node_index) < coordinates.len) {
            const context = coordinates[@backingInt(row.node_index)] orelse continue;
            // Placement changes positions only. Identity and use scopes remain
            // the exact values supplied by their individual reference creators.
            row.stmt_idx = context.stmt_idx;
            row.scope_stmt_idx = context.scope_stmt_idx;
        }
    }
    origins = self.native_arguments_declaration_origins.iterator();
    while (origins.next()) |entry| {
        if (!declarations.contains(entry.key_ptr.*)) @panic("native engine is missing its creation declaration");
    }
}
