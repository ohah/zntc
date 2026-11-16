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
    source_parameter_engine: bool = false,
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

/// Track a generated read of an existing parameter-engine identity. Unlike a
/// produced native engine, this reference does not create a new declaration;
/// publication only supplies its final statement coordinates.
pub fn recordParameterReference(self: anytype, node: ast.NodeIndex, id: SymbolId, owner_scope: ScopeId, use_scope: ScopeId) !void {
    var editor = self.semantic_editor orelse @panic("source parameter arguments reference has no semantic editor");
    const raw_id = @backingInt(id);
    if (@backingInt(node) < self.parser_node_count or self.getSymbolIdAt(node) != @as(?u32, raw_id) or
        raw_id >= editor.symbols.items.len or self.native_arguments_declaration_origins.contains(raw_id))
        @panic("source parameter arguments reference lost its exact source identity");
    if (owner_scope.isNone() or use_scope.isNone() or owner_scope == use_scope or
        owner_scope.toIndex() >= editor.scopes.items.len or use_scope.toIndex() >= editor.scopes.items.len or
        owner_scope.toIndex() >= editor.scope_maps.items.len or use_scope.toIndex() >= editor.scope_maps.items.len or
        editor.scopes.items[owner_scope.toIndex()].kind != .function or editor.scopes.items[use_scope.toIndex()].kind != .function or
        editor.scopes.items[use_scope.toIndex()].parent != owner_scope or
        editor.scope_maps.items[owner_scope.toIndex()].get("arguments") != raw_id or
        editor.scope_maps.items[use_scope.toIndex()].get("arguments") != null)
        @panic("source parameter arguments reference has no exact parameter/body edge");
    const symbol = editor.symbols.items[raw_id];
    if (symbol.scope_id != owner_scope or symbol.kind != .parameter or symbol.synthetic_kind != .implicit_arguments)
        @panic("source parameter arguments reference selected a non-engine symbol");
    const row = (try editor.referenceForNode(node)) orelse @panic("source parameter arguments reference lost its graph row");
    if (row.symbol_id != id or row.scope_id != use_scope or
        !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true })))
        @panic("source parameter arguments reference changed its creation tuple");
    const slot = try self.native_arguments_reference_origins.getOrPut(self.allocator, @backingInt(node));
    if (slot.found_existing) @panic("source parameter arguments reference has duplicate creation origins");
    slot.value_ptr.* = .{ .symbol_id = id, .owner_scope = owner_scope, .scope = use_scope, .source_parameter_engine = true };
}

pub fn publication(self: anytype, raw: u32) @import("../semantic/editor.zig").Error!?@import("transformer.zig").StatementPublication {
    const origin = self.native_arguments_reference_origins.get(raw) orelse return null;
    if (!validValueAccess(origin.flags)) return error.InvalidNode;
    const editor = &self.semantic_editor.?;
    const id = @backingInt(origin.symbol_id);
    if (id >= editor.symbols.items.len or editor.symbols.items[id].kind != .parameter or
        editor.symbols.items[id].synthetic_kind != .implicit_arguments) return error.InvalidSymbol;
    if (editor.symbols.items[id].scope_id != origin.owner_scope) return error.InvalidScope;
    if (origin.source_parameter_engine) {
        if (self.native_arguments_declaration_origins.contains(id) or origin.owner_scope.isNone() or origin.scope.isNone() or
            origin.owner_scope.toIndex() >= editor.scopes.items.len or origin.scope.toIndex() >= editor.scopes.items.len or
            origin.owner_scope.toIndex() >= editor.scope_maps.items.len or origin.scope.toIndex() >= editor.scope_maps.items.len or
            editor.scopes.items[origin.owner_scope.toIndex()].kind != .function or editor.scopes.items[origin.scope.toIndex()].kind != .function or
            editor.scopes.items[origin.scope.toIndex()].parent != origin.owner_scope or
            editor.scope_maps.items[origin.owner_scope.toIndex()].get("arguments") != id or
            editor.scope_maps.items[origin.scope.toIndex()].get("arguments") != null) return error.InvalidScope;
    } else if (self.native_arguments_declaration_origins.get(id) != origin.owner_scope) return error.InvalidScope;
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
        @backingInt(params) >= self.ast.nodes.items.len or
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

/// Return true only when an original reference to this engine lies inside the
/// source formal-list span. Reads from the function body do not prove that a
/// lowered default initializer needs the parameter environment's identity.
pub fn parameterEngineAccessInFormals(self: anytype, params: ast.NodeIndex, id: SymbolId) bool {
    if (!self.semantic_edit_enabled or params.isNone() or @backingInt(params) >= self.ast.nodes.items.len or
        self.ast.getNode(params).tag != .formal_parameters) return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    const source_params = if (self.scope_owner_origins.get(@backingInt(params))) |origin|
        @as(ast.NodeIndex, @fromBackingInt(origin))
    else
        params;
    if (@backingInt(source_params) >= self.ast.nodes.items.len or self.ast.getNode(source_params).tag != .formal_parameters) return false;
    const params_list = self.ast.getNode(source_params).data.list;
    for (editor.references.items) |row| {
        if (row.symbol_id != id or row.flags.declare or row.node_index.isNone() or
            @backingInt(row.node_index) >= self.parser_node_count) continue;
        const reference_span = self.ast.getNode(row.node_index).span;
        for (0..params_list.len) |offset| {
            const parameter = self.ast.getNode(self.ast.readExtraNode(params_list.start, @intCast(offset)));
            if (reference_span.start >= parameter.span.start and reference_span.end <= parameter.span.end) return true;
        }
    }
    return false;
}

/// Reuse the source implicit arguments identity when a downlevel parameter
/// initializer is emitted in its function body. The source parameter scope is
/// the exact lexical owner, and the body must not introduce its own binding.
pub fn existingParameterEngine(self: anytype, params: ast.NodeIndex, body_scope: ScopeId) ?SymbolId {
    if (!self.semantic_edit_enabled or params.isNone() or @backingInt(params) >= self.ast.nodes.items.len or
        self.ast.getNode(params).tag != .formal_parameters) return null;
    const parameter_scope = self.outputOwnedScope(params) orelse return null;
    const editor = if (self.semantic_editor) |*value| value else return null;
    if (parameter_scope.isNone() or body_scope.isNone() or parameter_scope == body_scope or
        parameter_scope.toIndex() >= editor.scopes.items.len or body_scope.toIndex() >= editor.scopes.items.len or
        parameter_scope.toIndex() >= editor.scope_maps.items.len or body_scope.toIndex() >= editor.scope_maps.items.len or
        editor.scopes.items[parameter_scope.toIndex()].kind != .function or editor.scopes.items[body_scope.toIndex()].kind != .function or
        editor.scopes.items[body_scope.toIndex()].parent != parameter_scope or
        editor.scope_maps.items[body_scope.toIndex()].get("arguments") != null) return null;
    const id = editor.scope_maps.items[parameter_scope.toIndex()].get("arguments") orelse return null;
    if (id >= editor.symbols.items.len) return null;
    const selected = editor.symbols.items[id];
    if (selected.scope_id != parameter_scope or selected.kind != .parameter or selected.synthetic_kind != .implicit_arguments or
        self.native_arguments_declaration_origins.contains(@intCast(id)) or
        !parameterEngineAccessInFormals(self, params, @fromBackingInt(@as(u32, @intCast(id))))) return null;
    for (editor.symbols.items, 0..) |symbol, other| {
        if (other != id and symbol.synthetic_kind == .implicit_arguments and
            (symbol.scope_id == parameter_scope or symbol.scope_id == body_scope)) return null;
    }
    return @fromBackingInt(@as(u32, @intCast(id)));
}

/// A lowered-arity snapshot reads the actual ordinary function's argument
/// list before Source initializers run. Unlike the unused-engine handoff this
/// producer can retain an already observed parameter engine in its existing
/// parameter carrier; it never creates a second engine in the body scope.
/// Null means an explicit Source binding prevents this output contract.
pub fn loweredArityEngineReference(
    self: anytype,
    function_owner: ast.NodeIndex,
    old_params: ast.NodeIndex,
    body_scope: ScopeId,
    span: @import("../lexer/token.zig").Span,
) !?ast.NodeIndex {
    if (!self.semantic_edit_enabled or !self.options.unsupported.default_params) return null;
    if (function_owner.isNone() or old_params.isNone() or
        @backingInt(function_owner) >= self.ast.nodes.items.len or @backingInt(old_params) >= self.ast.nodes.items.len)
        @panic("lowered arity arguments lost its actual function/parameter owner");
    const function = self.ast.getNode(function_owner);
    switch (function.tag) {
        .function, .function_expression, .function_declaration, .method_definition => {},
        else => return null,
    }
    if (self.ast.readExtraNode(function.data.extra, ast.FunctionExtra.params) != old_params or
        self.ast.getNode(old_params).tag != .formal_parameters or self.outputOwnedScope(function_owner) != body_scope)
        @panic("lowered arity arguments changed its actual formal/body edge");
    const parameter_scope = self.outputOwnedScope(old_params) orelse body_scope;
    const editor = if (self.semantic_editor) |*value| value else @panic("lowered arity arguments has no editor");
    if (body_scope.isNone() or parameter_scope.isNone() or
        body_scope.toIndex() >= editor.scopes.items.len or parameter_scope.toIndex() >= editor.scopes.items.len or
        body_scope.toIndex() >= editor.scope_maps.items.len or parameter_scope.toIndex() >= editor.scope_maps.items.len or
        editor.scopes.items[body_scope.toIndex()].kind != .function or editor.scopes.items[parameter_scope.toIndex()].kind != .function)
        @panic("lowered arity arguments has no actual ordinary function scope");
    // A Source parameter called arguments owns its own cell, not the engine.
    // Only an actual formal binding can release that spelling; dynamic name
    // lookup and arbitrary body shadows remain outside this producer.
    if (editor.scope_maps.items[parameter_scope.toIndex()].get("arguments")) |source_id| {
        if (source_id >= editor.symbols.items.len) @panic("lowered arity parameter is outside its symbol table");
        const source = editor.symbols.items[source_id];
        if (source.kind == .parameter and source.synthetic_kind == null and source.scope_id == parameter_scope) {
            if (editor.scopes.items[parameter_scope.toIndex()].blocksMangling() or editor.scopes.items[body_scope.toIndex()].blocksMangling()) return null;
            if (parameter_scope != body_scope and editor.scope_maps.items[body_scope.toIndex()].get("arguments") != null) return null;
            var actual_formal = false;
            const list = self.ast.getNode(old_params).data.list;
            for (0..list.len) |offset| {
                var bindings = try @import("../parser/ast_walk.zig").bindingIdentifiers(self.allocator, self.ast, self.ast.readExtraNode(list.start, @intCast(offset)), .{});
                defer bindings.deinit();
                while (try bindings.next()) |binding| {
                    if (self.ast.getNode(binding).tag == .binding_identifier and self.getSymbolIdAt(binding) == @as(?u32, @intCast(source_id))) actual_formal = true;
                }
            }
            if (!actual_formal) return null;
            const output = try @import("es_helpers.zig").resolveSyntheticNameAvoidingDynamicEval(self, "_arityArguments", parameter_scope);
            try editor.renameParameterEnvironmentBinding(@fromBackingInt(@as(u32, @intCast(source_id))), output);
            return try self.makeNativeArgumentsRef(body_scope, body_scope, span);
        }
    }
    if (parameter_scope == body_scope) {
        if (!hasAvailableEngineSlot(self, body_scope)) return null;
        return try self.makeNativeArgumentsRef(body_scope, body_scope, span);
    }
    if (editor.scopes.items[body_scope.toIndex()].parent != parameter_scope)
        @panic("lowered arity arguments changed its actual parameter/body scope pair");
    if (editor.scope_maps.items[body_scope.toIndex()].get("arguments")) |body_id| {
        // Repeated snapshot uses share only this producer's actual body engine.
        // An unrelated Source binding cannot acquire native-engine authority.
        if (body_id < editor.symbols.items.len and hasAvailableEngineSlot(self, body_scope) and
            self.native_arguments_declaration_origins.get(@intCast(body_id)) == body_scope)
            return try self.makeNativeArgumentsRef(body_scope, body_scope, span);
        return null;
    }
    const id = editor.scope_maps.items[parameter_scope.toIndex()].get("arguments") orelse {
        // A lowered arrow has a real ordinary output function but no Source
        // implicit engine. Its lexical arguments references already retain
        // their outer identity; the new input snapshot owns this output engine.
        return try self.makeNativeArgumentsRef(body_scope, body_scope, span);
    };
    if (id >= editor.symbols.items.len) @panic("lowered arity arguments engine is outside its symbol table");
    const selected = editor.symbols.items[id];
    if (selected.scope_id != parameter_scope or selected.kind != .parameter or selected.synthetic_kind != .implicit_arguments or selected.write_count != 0) return null;
    for (editor.symbols.items, 0..) |symbol, other| {
        if (other != id and symbol.synthetic_kind == .implicit_arguments and
            (symbol.scope_id == parameter_scope or symbol.scope_id == body_scope)) return null;
    }
    const symbol_id: SymbolId = @fromBackingInt(@as(u32, @intCast(id)));
    const reference = try self.makeSyntheticRefForSymbol(symbol_id, body_scope, .{ .read = true });
    if (self.native_arguments_declaration_origins.get(@intCast(id))) |owner| {
        if (owner != parameter_scope) @panic("lowered arity arguments changed its existing engine owner");
        const handoff = self.native_arguments_parameter_handoffs.get(@intCast(id)) orelse
            @panic("lowered arity arguments produced engine has no exact parameter handoff");
        if (handoff.params != old_params or handoff.source_scope != parameter_scope or handoff.body_scope != body_scope)
            @panic("lowered arity arguments changed its existing handoff edge");
        try recordReference(self, reference, symbol_id, parameter_scope, body_scope);
    } else {
        try recordParameterReference(self, reference, symbol_id, parameter_scope, body_scope);
    }
    return reference;
}

pub const ArityOwnerInput = struct {
    binding: ast.NodeIndex,
    symbol: SymbolId,
    before: @import("../semantic/symbol.zig").Symbol,
    output_binding: ast.NodeIndex,
    snapshot: ast.NodeIndex,
};

/// Captured by the actual slot producer before changing parameter storage.
/// Inputs are emitter-arena owned and must outlive this completion call.
pub const ArityOwnerCompletion = struct {
    ast_owner: *const ast.Ast,
    function_owner: ast.NodeIndex,
    params: ast.NodeIndex,
    body_scope: ScopeId,
    cutoff: u32,
    inputs: []const ArityOwnerInput,
};

/// Complete only a zero-cutoff arity replacement whose actual input cells
/// already entered body storage. Retire the obsolete header owner, not its
/// lexical frame: later name-elision still owns that independent transaction.
pub fn completeErasedArityOwner(
    self: anytype,
    owner: @import("es2015_params.zig").RestArgumentsOwner,
    new_params: ast.NodeIndex,
    pending_statements: []const ast.NodeIndex,
    output_root: ast.NodeIndex,
    completion: ?ArityOwnerCompletion,
) !bool {
    if (!self.semantic_edit_enabled or !self.options.unsupported.default_params) return false;
    if (owner.ast_owner != self.ast or owner.function_node.isNone() or owner.params_node.isNone() or new_params.isNone() or output_root.isNone()) return error.InvalidNode;
    for ([_]ast.NodeIndex{ owner.function_node, owner.params_node, new_params, output_root }) |node|
        if (@backingInt(node) >= self.ast.nodes.items.len) return error.InvalidNode;
    const function = self.ast.getNode(owner.function_node);
    switch (function.tag) {
        .function, .function_expression, .function_declaration, .method_definition => {},
        else => return error.InvalidNode,
    }
    if (self.outputOwnedScope(owner.function_node) != owner.body_scope or
        self.ast.readExtraNode(function.data.extra, ast.FunctionExtra.params) != new_params) return error.InvalidScope;
    const proof = completion orelse return false;
    if (proof.ast_owner != self.ast or proof.function_owner != owner.function_node or proof.params != owner.params_node or proof.body_scope != owner.body_scope or proof.cutoff != 0) return error.InvalidNode;
    const old = self.ast.getNode(owner.params_node);
    const replacement = self.ast.getNode(new_params);
    if (old.tag != .formal_parameters or replacement.tag != .formal_parameters) return error.InvalidNode;
    if (replacement.data.list.len != 0 or old.data.list.len == 0) return false;
    if (proof.inputs.len != old.data.list.len) return error.InvalidNode;
    const p = self.outputOwnedScope(owner.params_node) orelse return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    if (p == owner.body_scope or p.isNone() or p.toIndex() >= editor.scopes.items.len or
        owner.body_scope.toIndex() >= editor.scopes.items.len) return false;
    if (editor.scopes.items[p.toIndex()].kind != .function or
        editor.scopes.items[owner.body_scope.toIndex()].kind != .function or
        editor.scopes.items[owner.body_scope.toIndex()].parent != p or
        editor.scopes.items[p.toIndex()].symbol_count != 0 or editor.scope_maps.items[p.toIndex()].count() != 0) return false;
    if (self.outputOwnedScope(new_params) != null) return false;
    var carrier = owner.params_node;
    var remaining = self.ast.nodes.items.len;
    while (self.scope_owner_origins.get(@backingInt(carrier))) |origin| {
        if (origin == @backingInt(carrier)) break;
        if (origin >= self.ast.nodes.items.len or remaining == 0) return error.InvalidNode;
        remaining -= 1;
        carrier = @fromBackingInt(origin);
    }
    if (editor.scope_owner_map.get(@backingInt(carrier)) != @as(?u32, @backingInt(p))) return false;
    const source_header = self.ast.getNode(carrier);
    if (source_header.tag != .formal_parameters or source_header.data.list.len != old.data.list.len) return error.InvalidNode;
    // This completion exists only for the named-function environment whose
    // later retirement needs its exact obsolete header alias accounted for.
    const function_name = self.ast.readExtraNode(function.data.extra, ast.FunctionExtra.name);
    if (function.tag != .function_expression or function_name.isNone()) return false;
    const name_sid = self.getSymbolIdAt(function_name) orelse return error.InvalidSymbol;
    if (name_sid >= editor.symbols.items.len) return error.InvalidSymbol;
    const name_symbol = editor.symbols.items[name_sid];
    if (name_symbol.reference_count != 0 or name_symbol.write_count != 0) {
        return false;
    }
    const name_scope = name_symbol.scope_id;
    if (editor.scopes.items[p.toIndex()].parent != name_scope or name_scope.isNone() or
        name_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[name_scope.toIndex()].kind != .block) return false;
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, output_root);
    defer self.allocator.free(live);
    for (live) |raw| {
        const candidate = self.ast.nodes.items[raw];
        switch (candidate.tag) {
            .function, .function_expression, .function_declaration, .method_definition => {},
            else => continue,
        }
        if (@as(ast.NodeIndex, @fromBackingInt(raw)) == owner.function_node) continue;
        const params = self.ast.readExtraNode(candidate.data.extra, ast.FunctionExtra.params);
        if (params == owner.params_node or params == carrier) return false;
    }
    for (live) |raw| if (raw == @backingInt(carrier)) return false;
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(self.allocator);
    for (pending_statements) |statement| {
        const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, statement);
        defer self.allocator.free(nodes);
        try pending.appendSlice(self.allocator, nodes);
    }
    for (0..old.data.list.len) |offset| {
        const formal_index = self.ast.readExtraNode(old.data.list.start, @intCast(offset));
        const formal = self.ast.getNode(formal_index);
        const binding = switch (formal.tag) {
            .binding_identifier => formal_index,
            .assignment_pattern => formal.data.binary.left,
            .formal_parameter => self.ast.readExtraNode(formal.data.extra, ast.FormalParameterExtra.pattern),
            else => return false,
        };
        if (binding.isNone() or self.ast.getNode(binding).tag != .binding_identifier) return false;
        const source_formal_index = self.ast.readExtraNode(source_header.data.list.start, @intCast(offset));
        const source_formal = self.ast.getNode(source_formal_index);
        const source_binding = switch (source_formal.tag) {
            .binding_identifier => source_formal_index,
            .assignment_pattern => source_formal.data.binary.left,
            .formal_parameter => self.ast.readExtraNode(source_formal.data.extra, ast.FormalParameterExtra.pattern),
            else => return error.InvalidNode,
        };
        if (self.getSymbolIdAt(source_binding) != self.getSymbolIdAt(binding)) return error.InvalidSymbol;
        const sid = self.getSymbolIdAt(binding) orelse return error.InvalidSymbol;
        if (sid >= editor.symbols.items.len) return error.InvalidSymbol;
        const symbol = editor.symbols.items[sid];
        const input_proof = proof.inputs[offset];
        if (input_proof.binding != binding or @backingInt(input_proof.symbol) != sid or
            input_proof.before.kind != .parameter or input_proof.before.synthetic_kind == .implicit_arguments or
            (input_proof.before.scope_id != p and input_proof.before.scope_id != owner.body_scope) or
            input_proof.before.scope_id.isNone() or symbol.scope_id != owner.body_scope or symbol.kind != .variable_var or
            self.getSymbolIdAt(input_proof.output_binding) != @as(?u32, sid)) return error.InvalidScope;
        const before_map = editor.scope_maps.items[owner.body_scope.toIndex()];
        const output_symbol_name = if (symbol.synthetic_name.len != 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        if (before_map.get(output_symbol_name) != @as(?usize, sid)) return error.InvalidSymbol;
        var snapshots: usize = 0;
        for (pending.items) |raw| {
            const declaration = self.ast.nodes.items[raw];
            if (declaration.tag != .variable_declarator or @as(ast.NodeIndex, @fromBackingInt(raw)) != input_proof.snapshot) continue;
            const target = self.ast.readExtraNode(declaration.data.extra, 0);
            if (target != input_proof.output_binding) return error.InvalidNode;
            if (self.getSymbolIdAt(target) != @as(?u32, sid)) continue;
            const value = self.ast.readExtraNode(declaration.data.extra, 2);
            if (value.isNone() or self.ast.getNode(value).tag != .conditional_expression) continue;
            const input = self.ast.getNode(value).data.ternary;
            const condition = self.ast.getNode(input.a);
            if (condition.tag != .binary_expression or condition.data.binary.flags != @backingInt(@import("../lexer/token.zig").Kind.r_angle)) continue;
            const length = self.ast.getNode(condition.data.binary.left);
            const slot = self.ast.getNode(input.b);
            if (length.tag != .static_member_expression or slot.tag != .computed_member_expression) continue;
            const key = self.ast.readExtraNode(length.data.extra, 1);
            if (!std.mem.eql(u8, self.ast.getText(self.ast.getNode(key).data.string_ref), "length")) continue;
            const bound = self.ast.getNode(condition.data.binary.right);
            const index = self.ast.getNode(self.ast.readExtraNode(slot.data.extra, 1));
            if (bound.tag != .numeric_literal or index.tag != .numeric_literal or
                (std.fmt.parseInt(usize, self.ast.getText(bound.span), 10) catch continue) != offset or
                (std.fmt.parseInt(usize, self.ast.getText(index.span), 10) catch continue) != offset) continue;
            const count_ref = self.ast.readExtraNode(length.data.extra, 0);
            const value_ref = self.ast.readExtraNode(slot.data.extra, 0);
            if (count_ref == value_ref) return error.InvalidNode;
            const engine = self.getSymbolIdAt(count_ref) orelse return error.InvalidSymbol;
            if (self.getSymbolIdAt(value_ref) != @as(?u32, engine) or engine >= editor.symbols.items.len or
                editor.symbols.items[engine].synthetic_kind != .implicit_arguments or editor.symbols.items[engine].scope_id != owner.body_scope or
                self.native_arguments_declaration_origins.get(engine) != owner.body_scope) return error.InvalidSymbol;
            for ([_]ast.NodeIndex{ count_ref, value_ref }) |reference| {
                const origin = self.native_arguments_reference_origins.get(@backingInt(reference)) orelse return error.InvalidNode;
                if (@backingInt(origin.symbol_id) != engine or origin.owner_scope != owner.body_scope or origin.scope != owner.body_scope) return error.InvalidScope;
                _ = (try publication(self, @backingInt(reference))) orelse return error.InvalidNode;
            }
            snapshots += 1;
        }
        if (snapshots != 1) return error.InvalidNode;
    }
    // Reserve every fallible publication before changing either owner edge.
    try self.scope_owner_removed.ensureUnusedCapacity(self.allocator, 1);
    try self.transformed_scope_owner_map.ensureUnusedCapacity(self.allocator, 1);
    try editor.scope_owner_map.ensureUnusedCapacity(self.allocator, 1);
    try editor.scope_history.events.ensureUnusedCapacity(self.allocator, 2);
    // The exact old carrier has no remaining live function consumer. Preserve
    // its immutable Source node and record only completion of its owner role.
    try self.scope_owner_removed.put(self.allocator, @backingInt(carrier), {});
    _ = self.scope_owner_remaps.remove(@backingInt(carrier));
    _ = self.transformed_scope_owner_map.remove(@backingInt(carrier));
    if (!try editor.removeScopeOwner(carrier)) return error.InvalidScope;
    // P remains a real lexical frame even when no name-elision pass follows.
    // Its actual replacement header owns it until that separate transaction.
    try editor.putScopeOwner(new_params, p);
    try self.transformed_scope_owner_map.put(self.allocator, @backingInt(new_params), @backingInt(p));
    return true;
}

pub fn record(self: anytype, id: SymbolId, scope: ScopeId) !void {
    const slot = try self.native_arguments_declaration_origins.getOrPut(self.allocator, @backingInt(id));
    if (slot.found_existing and slot.value_ptr.* != scope)
        @panic("native engine changed its creation scope");
    slot.value_ptr.* = scope;
}

pub fn publish(self: anytype, root: ast.NodeIndex) !void {
    if (!self.semantic_edit_enabled or
        (self.native_arguments_declaration_origins.count() == 0 and self.native_arguments_reference_origins.count() == 0)) return;
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
        if (origin.source_parameter_engine) {
            if (!validValueAccess(origin.flags) or row.symbol_id != origin.symbol_id or row.scope_id != origin.scope or
                self.getSymbolIdAt(@fromBackingInt(raw)) != @as(?u32, @backingInt(origin.symbol_id)) or
                !std.meta.eql(row.flags, origin.flags)) @panic("source parameter arguments reference changed its creation tuple");
            origin.stmt = context.stmt_idx;
            origin.scope_stmt = context.scope_stmt_idx;
            var found = false;
            for (editor.references.items) |*reference| {
                if (@backingInt(reference.node_index) != raw) continue;
                reference.stmt_idx = context.stmt_idx;
                reference.scope_stmt_idx = context.scope_stmt_idx;
                found = true;
            }
            if (!found) @panic("source parameter arguments reference has no row to publish");
            _ = (publication(self, raw) catch @panic("source parameter arguments reference lost its publication tuple")) orelse
                @panic("source parameter arguments reference has no publication record");
            continue;
        }
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
