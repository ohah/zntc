//! Position publication for native engine identities recorded at creation.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Context = @import("../semantic/statement_coordinates.zig").Context;

pub const ReferenceOrigin = struct {
    symbol_id: SymbolId,
    owner_scope: ScopeId,
    scope: ScopeId,
    stmt: u32 = std.math.maxInt(u32),
    scope_stmt: u32 = std.math.maxInt(u32),
};

pub fn recordReference(self: anytype, node: ast.NodeIndex, id: SymbolId, owner_scope: ScopeId, use_scope: ScopeId) !void {
    if (@backingInt(node) < self.parser_node_count or self.getSymbolIdAt(node) != @as(?u32, @backingInt(id)) or
        self.native_arguments_declaration_origins.get(@backingInt(id)) != owner_scope)
        @panic("native arguments reference lost its exact creator");
    const slot = try self.native_arguments_reference_origins.getOrPut(self.allocator, @backingInt(node));
    if (slot.found_existing) @panic("native arguments reference has duplicate creation origins");
    slot.value_ptr.* = .{ .symbol_id = id, .owner_scope = owner_scope, .scope = use_scope };
}

pub fn publication(self: anytype, raw: u32) @import("../semantic/editor.zig").Error!?@import("transformer.zig").StatementPublication {
    const origin = self.native_arguments_reference_origins.get(raw) orelse return null;
    const editor = &self.semantic_editor.?;
    const id = @backingInt(origin.symbol_id);
    if (id >= editor.symbols.items.len or editor.symbols.items[id].kind != .parameter or
        editor.symbols.items[id].synthetic_kind != .implicit_arguments) return error.InvalidSymbol;
    if (editor.symbols.items[id].scope_id != origin.owner_scope or
        self.native_arguments_declaration_origins.get(id) != origin.owner_scope) return error.InvalidScope;
    const row = (try editor.referenceForNode(@fromBackingInt(raw))) orelse return error.ReferenceNotFound;
    if (row.symbol_id != origin.symbol_id or self.getSymbolIdAt(@fromBackingInt(raw)) != @as(?u32, id)) return error.InvalidSymbol;
    if (row.scope_id != origin.scope) return error.InvalidScope;
    if (row.stmt_idx != origin.stmt or row.scope_stmt_idx != origin.scope_stmt or
        !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true }))) return error.InvalidNode;
    return .{ .symbol_id = origin.symbol_id, .scope = origin.scope, .stmt = origin.stmt, .scope_stmt = origin.scope_stmt };
}

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

/// Kept non-simple formals own the native engine outside their body scope.
/// The exact parameter edge and parent relationship provide the environment;
/// an emitted body binding must not shadow the engine being forwarded.
pub fn hasRetainedParameterEngine(self: anytype, params: ast.NodeIndex, body_scope: ScopeId) bool {
    if (!self.semantic_edit_enabled or self.options.unsupported.default_params or params.isNone() or
        self.ast.getNode(params).tag != .formal_parameters) return false;
    const parameter_scope = self.outputOwnedScope(params) orelse return false;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const maps = if (self.semantic_editor) |*editor| editor.scope_maps.items else self.scope_maps;
    if (parameter_scope == body_scope or body_scope.isNone() or parameter_scope.isNone() or
        body_scope.toIndex() >= scopes.len or parameter_scope.toIndex() >= scopes.len or body_scope.toIndex() >= maps.len or
        scopes[body_scope.toIndex()].kind != .function or scopes[parameter_scope.toIndex()].kind != .function or
        scopes[body_scope.toIndex()].parent != parameter_scope or maps[body_scope.toIndex()].get("arguments") != null) return false;
    return hasAvailableEngineSlot(self, parameter_scope);
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
        if (wanted.contains(scope)) {
            const slot = try owners.getOrPut(self.allocator, scope);
            if (slot.found_existing) @panic("native engine has multiple current function owners");
            slot.value_ptr.* = context;
        }
        switch (self.ast.nodes.items[raw].tag) {
            .function, .function_expression, .function_declaration, .method_definition => {},
            else => continue,
        }
        const params = self.ast.readExtraNode(self.ast.nodes.items[raw].data.extra, ast.FunctionExtra.params);
        if (params.isNone()) continue;
        const parameter_scope = self.outputOwnedScope(params) orelse continue;
        if (parameter_scope == scope or !wanted.contains(parameter_scope)) continue;
        if (self.ast.getNode(params).tag != .formal_parameters or scope.isNone() or parameter_scope.isNone() or
            scope.toIndex() >= editor.scopes.items.len or parameter_scope.toIndex() >= editor.scopes.items.len or
            editor.scopes.items[scope.toIndex()].kind != .function or editor.scopes.items[parameter_scope.toIndex()].kind != .function or
            editor.scopes.items[scope.toIndex()].parent != parameter_scope)
            @panic("native parameter engine has no exact current parameter carrier");
        const slot = try owners.getOrPut(self.allocator, parameter_scope);
        if (slot.found_existing) @panic("native parameter engine has multiple current function owners");
        slot.value_ptr.* = context;
    }
    var reference_origins = self.native_arguments_reference_origins.iterator();
    while (reference_origins.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= coordinates.len) @panic("native arguments reference is outside its AST");
        const context = coordinates[raw] orelse continue;
        const origin = entry.value_ptr;
        const row = (editor.referenceForNode(@fromBackingInt(raw)) catch @panic("native arguments reference is ambiguous")) orelse
            @panic("native arguments reference lost its creation row");
        if (self.native_arguments_declaration_origins.get(@backingInt(origin.symbol_id)) != origin.owner_scope or
            row.symbol_id != origin.symbol_id or row.scope_id != origin.scope or
            self.getSymbolIdAt(@fromBackingInt(raw)) != @as(?u32, @backingInt(origin.symbol_id)) or
            !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true })))
            @panic("native arguments reference changed its creation tuple");
        origin.stmt = context.stmt_idx;
        origin.scope_stmt = context.scope_stmt_idx;
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
