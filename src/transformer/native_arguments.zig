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
    flags: @import("../semantic/symbol.zig").ReferenceFlags = .{ .read = true },
    stmt: u32 = std.math.maxInt(u32),
    scope_stmt: u32 = std.math.maxInt(u32),
};

pub const ParameterHandoff = struct {
    params: ast.NodeIndex,
    source_scope: ScopeId,
    body_scope: ScopeId,
};

fn validValueAccess(flags: @import("../semantic/symbol.zig").ReferenceFlags) bool {
    return (flags.read or flags.write) and std.meta.eql(flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = flags.read, .write = flags.write }));
}

/// Only an unobserved source engine may be forwarded before its parameter
/// environment is erased. The actual parameter replacement consumes the plan.
pub fn canHandoffParameterEngine(self: anytype, params: ast.NodeIndex, body_scope: ScopeId) bool {
    if (!self.semantic_edit_enabled or !self.options.unsupported.default_params or params.isNone() or @backingInt(params) >= self.ast.nodes.items.len or
        self.ast.getNode(params).tag != .formal_parameters) return false;
    // Split rest formals have a separate arguments producer. It must acquire
    // this same engine before that environment can participate in a handoff.
    const formals = self.ast.getNode(params).data.list;
    for (0..formals.len) |offset| {
        const formal = self.ast.getNode(self.ast.readExtraNode(formals.start, @intCast(offset)));
        if (formal.tag == .rest_element or formal.tag == .spread_element) return false;
    }
    const source_scope = self.outputOwnedScope(params) orelse return false;
    const editor = &self.semantic_editor.?;
    if (source_scope == body_scope or source_scope.isNone() or body_scope.isNone() or
        source_scope.toIndex() >= editor.scopes.items.len or body_scope.toIndex() >= editor.scopes.items.len or
        source_scope.toIndex() >= editor.scope_maps.items.len or body_scope.toIndex() >= editor.scope_maps.items.len or
        editor.scopes.items[source_scope.toIndex()].kind != .function or editor.scopes.items[body_scope.toIndex()].kind != .function or
        editor.scopes.items[body_scope.toIndex()].parent != source_scope or
        editor.scope_maps.items[body_scope.toIndex()].get("arguments") != null) return false;
    const id = editor.scope_maps.items[source_scope.toIndex()].get("arguments") orelse return false;
    if (id >= editor.symbols.items.len) return false;
    const selected = editor.symbols.items[id];
    if (selected.scope_id != source_scope or selected.kind != .parameter or selected.synthetic_kind != .implicit_arguments or
        selected.reference_count != 0 or selected.write_count != 0 or self.native_arguments_declaration_origins.contains(@intCast(id))) return false;
    for (editor.symbols.items, 0..) |symbol, other| {
        if (other != id and symbol.synthetic_kind == .implicit_arguments and
            (symbol.scope_id == source_scope or symbol.scope_id == body_scope)) return false;
    }
    var declarations: usize = 0;
    for (editor.references.items) |row| {
        if (@backingInt(row.symbol_id) != id) continue;
        if (!row.node_index.isNone() or !row.declaration_node_index.isNone() or row.scope_id != source_scope or
            !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) return false;
        declarations += 1;
    }
    return declarations == 1;
}

/// Called only after the producer publishes the actual outer formal edge.
pub fn recordParameterHandoff(self: anytype, reference: ast.NodeIndex, params: ast.NodeIndex, body_scope: ScopeId) !void {
    const origin = self.native_arguments_reference_origins.get(@backingInt(reference)) orelse return error.InvalidNode;
    if (params.isNone() or @backingInt(params) >= self.ast.nodes.items.len or self.ast.getNode(params).tag != .formal_parameters) return error.InvalidNode;
    if (origin.scope != body_scope or self.outputOwnedScope(params) != origin.owner_scope) return error.InvalidScope;
    _ = try publication(self, @backingInt(reference));
    const slot = try self.native_arguments_parameter_handoffs.getOrPut(self.allocator, @backingInt(origin.symbol_id));
    if (slot.found_existing) return error.InvalidSymbol;
    slot.value_ptr.* = .{ .params = params, .source_scope = origin.owner_scope, .body_scope = body_scope };
}

/// The ES5 class method creator copies these exact already visited formals.
pub fn copyParameterHandoff(self: anytype, old: ast.NodeIndex, new: ast.NodeIndex, body_scope: ScopeId) void {
    var plans = self.native_arguments_parameter_handoffs.iterator();
    while (plans.next()) |entry| {
        const plan = entry.value_ptr;
        if (plan.params != old) continue;
        if (plan.body_scope != body_scope or self.outputOwnedScope(old) != plan.source_scope or
            self.outputOwnedScope(new) != plan.source_scope or self.ast.getNode(old).tag != .formal_parameters or
            self.ast.getNode(new).tag != .formal_parameters or
            !std.meta.eql(self.ast.getNode(old).data.list, self.ast.getNode(new).data.list))
            @panic("copied parameter handoff lost its actual formal edge");
        plan.params = new;
    }
}

/// The driver has validated the actual new simple formals and body owner.
/// Preserve every use identity and scope; only the native declaration moves.
pub fn completeParameterHandoff(self: anytype, function_owner: ast.NodeIndex, params: ast.NodeIndex, new_params: ast.NodeIndex, body_scope: ScopeId) !bool {
    var plans = self.native_arguments_parameter_handoffs.iterator();
    var selected: ?u32 = null;
    while (plans.next()) |entry| {
        if (entry.value_ptr.params != params) continue;
        if (selected != null) return error.InvalidSymbol;
        selected = entry.key_ptr.*;
    }
    const id = selected orelse return false;
    const plan = self.native_arguments_parameter_handoffs.get(id).?;
    const editor = &self.semantic_editor.?;
    if (function_owner.isNone() or @backingInt(function_owner) >= self.ast.nodes.items.len or
        new_params.isNone() or @backingInt(new_params) >= self.ast.nodes.items.len or new_params == params) return error.InvalidNode;
    const function = self.ast.getNode(function_owner);
    switch (function.tag) {
        .function, .function_expression, .function_declaration, .method_definition => {},
        else => return error.InvalidNode,
    }
    if (self.outputOwnedScope(function_owner) != body_scope or self.outputOwnedScope(new_params) != null) return error.InvalidScope;
    if (self.ast.readExtraNode(function.data.extra, ast.FunctionExtra.params) != new_params or
        self.ast.getNode(new_params).tag != .formal_parameters) return error.InvalidNode;
    const new_list = self.ast.getNode(new_params).data.list;
    for (0..new_list.len) |offset| {
        if (@import("native_constructor_timing.zig").simpleFormalBinding(self, self.ast.readExtraNode(new_list.start, @intCast(offset))) == null)
            return error.InvalidNode;
    }
    if (plan.body_scope != body_scope or self.outputOwnedScope(params) != plan.source_scope or
        self.native_arguments_declaration_origins.get(id) != plan.source_scope) return error.InvalidScope;
    if (body_scope.isNone() or plan.source_scope.isNone() or body_scope.toIndex() >= editor.scopes.items.len or
        plan.source_scope.toIndex() >= editor.scopes.items.len or body_scope.toIndex() >= editor.scope_maps.items.len or
        plan.source_scope.toIndex() >= editor.scope_maps.items.len or editor.scopes.items[body_scope.toIndex()].kind != .function or
        editor.scopes.items[plan.source_scope.toIndex()].kind != .function or editor.scopes.items[body_scope.toIndex()].parent != plan.source_scope or
        editor.scope_maps.items[body_scope.toIndex()].get("arguments") != null) return error.InvalidScope;
    if (id >= editor.symbols.items.len) return error.InvalidSymbol;
    const symbol = editor.symbols.items[id];
    if (symbol.kind != .parameter or symbol.synthetic_kind != .implicit_arguments or symbol.write_count != 0) return error.InvalidSymbol;
    if (symbol.scope_id != plan.source_scope or editor.scope_maps.items[plan.source_scope.toIndex()].get("arguments") != @as(?usize, id)) return error.InvalidScope;
    for (editor.symbols.items) |other| {
        if (other.synthetic_kind == .implicit_arguments and other.scope_id == body_scope) return error.InvalidScope;
    }
    var declarations: usize = 0;
    var reads: usize = 0;
    for (editor.references.items) |row| {
        if (@backingInt(row.symbol_id) != id) continue;
        if (row.flags.declare) {
            if (!row.node_index.isNone() or !row.declaration_node_index.isNone() or row.scope_id != plan.source_scope or
                !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) return error.InvalidNode;
            declarations += 1;
        } else {
            const origin = self.native_arguments_reference_origins.get(@backingInt(row.node_index)) orelse return error.InvalidNode;
            if (@backingInt(origin.symbol_id) != id or self.getSymbolIdAt(row.node_index) != @as(?u32, id)) return error.InvalidSymbol;
            if (origin.owner_scope != plan.source_scope or origin.scope != body_scope or row.scope_id != body_scope) return error.InvalidScope;
            if (origin.stmt != row.stmt_idx or origin.scope_stmt != row.scope_stmt_idx or
                !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true }))) return error.InvalidNode;
            reads += 1;
        }
    }
    if (declarations != 1 or reads == 0 or symbol.reference_count != reads) return error.InvalidNode;
    var checked_origins: usize = 0;
    var created = self.native_arguments_reference_origins.iterator();
    while (created.next()) |entry| {
        const origin = entry.value_ptr.*;
        if (@backingInt(origin.symbol_id) != id) continue;
        if (origin.owner_scope != plan.source_scope or origin.scope != body_scope) return error.InvalidScope;
        _ = try publication(self, entry.key_ptr.*);
        checked_origins += 1;
    }
    if (checked_origins != reads) return error.InvalidNode;
    try self.moveSymbolToOutputScope(id, body_scope);
    self.native_arguments_declaration_origins.getPtr(id).?.* = body_scope;
    var origins = self.native_arguments_reference_origins.iterator();
    while (origins.next()) |entry| {
        if (@backingInt(entry.value_ptr.symbol_id) == id) entry.value_ptr.owner_scope = body_scope;
    }
    _ = self.native_arguments_parameter_handoffs.remove(id);
    return true;
}

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
    if (!validValueAccess(origin.flags)) return error.InvalidNode;
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
        !std.meta.eql(row.flags, origin.flags)) return error.InvalidNode;
    return .{ .symbol_id = origin.symbol_id, .scope = origin.scope, .stmt = origin.stmt, .scope_stmt = origin.scope_stmt };
}

/// An actual assignment producer consumes its known read and publishes the
/// new access flags. Identity, owner, use scope, and positions stay unchanged.
pub fn recordAssignment(self: anytype, node: ast.NodeIndex, flags: @import("../semantic/symbol.zig").ReferenceFlags) @import("../semantic/editor.zig").Error!void {
    if (!flags.write or !validValueAccess(flags)) return error.InvalidNode;
    _ = (try publication(self, @backingInt(node))) orelse return error.InvalidNode;
    try self.semantic_editor.?.updateReferenceFlags(node, flags);
    self.native_arguments_reference_origins.getPtr(@backingInt(node)).?.flags = flags;
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
        if (!validValueAccess(origin.flags) or self.native_arguments_declaration_origins.get(@backingInt(origin.symbol_id)) != origin.owner_scope or
            row.symbol_id != origin.symbol_id or row.scope_id != origin.scope or
            self.getSymbolIdAt(@fromBackingInt(raw)) != @as(?u32, @backingInt(origin.symbol_id)) or
            !std.meta.eql(row.flags, origin.flags))
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
