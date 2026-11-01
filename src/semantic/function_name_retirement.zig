//! Exact named-function environment removal, authorized by its name-slot producer.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const symbol = @import("symbol.zig");
const Scope = @import("scope.zig").Scope;
const ScopeId = @import("scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;
const Reference = symbol.Reference;
const History = @import("scope_frame_history.zig");

pub const Elision = struct {
    owner: NodeIndex,
    owner_node: ast_mod.Node,
    name: NodeIndex,
    name_node: ast_mod.Node,
    symbol_id: symbol.SymbolId,
    parameters: NodeIndex,
    body: NodeIndex,
};

pub const Formal = struct {
    binding: NodeIndex,
    node: ast_mod.Node,
    symbol_id: symbol.SymbolId,
    before: symbol.Symbol,
    declaration: Reference,
};
pub const Engine = struct { symbol_id: symbol.SymbolId, before: symbol.Symbol, declaration: Reference };

pub const OwnerAlias = struct { scope: ScopeId, owner: History.Owner };

pub const Witness = struct {
    event: Elision,
    name_scope: ScopeId,
    parameter_scope: ScopeId,
    retire_parameters: bool,
    body_scope: ScopeId,
    outer_scope: ScopeId,
    name_frame: Scope,
    parameter_frame: Scope,
    body_frame: Scope,
    formals: []const Formal,
    engine: ?Engine,
    owners: []const OwnerAlias,
};
pub const Source = struct {
    domain: *const ast_mod.Ast,
    backing: []const u8,
    root: NodeIndex,
    before: symbol.Symbol,
    declaration: Reference,
    witness: Witness,
};

fn sameOwner(a: ast_mod.Node, b: ast_mod.Node) bool {
    return a.tag == .function_expression and b.tag == a.tag and std.meta.eql(a.span, b.span) and a.data.extra == b.data.extra;
}
fn sameName(a: ast_mod.Node, b: ast_mod.Node) bool {
    return a.tag == .binding_identifier and b.tag == a.tag and std.meta.eql(a.span, b.span) and std.meta.eql(a.data.string_ref, b.data.string_ref);
}
fn formalBinding(ast: *const ast_mod.Ast, parameter: NodeIndex, preserve_expressions: bool) ?NodeIndex {
    if (parameter.isNone() or @backingInt(parameter) >= ast.nodes.items.len) return null;
    const node = ast.getNode(parameter);
    if (node.tag == .binding_identifier) return parameter;
    const binding = switch (node.tag) {
        .assignment_pattern => if (preserve_expressions) node.data.binary.left else return null,
        .formal_parameter => if (ast.hasExtra(node.data.extra, ast_mod.FormalParameterExtra.flags) and (preserve_expressions or ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.default).isNone())) ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.pattern) else return null,
        else => return null,
    };
    if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier) return null;
    return binding;
}

fn actualFormals(a: std.mem.Allocator, editor: anytype, parameters: NodeIndex, body_scope: ScopeId, preserve_expressions: bool) !?[]const Formal {
    if (parameters.isNone() or @backingInt(parameters) >= editor.ast.nodes.items.len) return null;
    const node = editor.ast.getNode(parameters);
    if (node.tag != .formal_parameters or node.data.list.start > editor.ast.extra_data.items.len or node.data.list.len > editor.ast.extra_data.items.len - node.data.list.start) return null;
    if (editor.scope_owner_map.get(@backingInt(parameters))) |owner| if (owner != @backingInt(body_scope)) return null;
    var result: std.ArrayList(Formal) = .empty;
    defer result.deinit(a);
    for (editor.ast.extra_data.items[node.data.list.start..][0..node.data.list.len]) |raw| {
        const binding = formalBinding(editor.ast, @fromBackingInt(raw), preserve_expressions) orelse return null;
        if (@backingInt(binding) >= editor.symbol_ids.items.len) return null;
        const id = editor.symbol_ids.items[@backingInt(binding)] orelse return null;
        if (id >= editor.symbols.items.len) return null;
        const before = editor.symbols.items[id];
        if (before.kind != .parameter or before.scope_id != body_scope or before.synthetic_kind == .implicit_arguments or
            !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(editor.ast.getText(editor.ast.getNode(binding).data.string_ref), if (before.synthetic_name.len != 0) before.synthetic_name else editor.ast.getText(before.name))) return null;
        for (result.items) |previous| if (previous.symbol_id == @as(symbol.SymbolId, @fromBackingInt(id)) or previous.binding == binding) return null;
        var declaration: ?Reference = null;
        for (editor.references.items) |row| if (@backingInt(row.symbol_id) == id and row.flags.declare) {
            if (declaration != null or row.scope_id != body_scope or !row.node_index.isNone() or row.declaration_node_index != binding or !std.meta.eql(row.flags, @as(symbol.ReferenceFlags, .{ .declare = true }))) return null;
            declaration = row;
        };
        try result.append(a, .{ .binding = binding, .node = editor.ast.getNode(binding), .symbol_id = @fromBackingInt(id), .before = before, .declaration = declaration orelse return null });
    }
    return try result.toOwnedSlice(a);
}

fn oldFormalBinding(ast: *const ast_mod.Ast, parameter: NodeIndex) ?NodeIndex {
    if (parameter.isNone() or @backingInt(parameter) >= ast.nodes.items.len) return null;
    const node = ast.getNode(parameter);
    if (node.tag == .binding_identifier) return parameter;
    const binding = switch (node.tag) {
        .assignment_pattern => node.data.binary.left,
        .formal_parameter => if (ast.hasExtra(node.data.extra, ast_mod.FormalParameterExtra.pattern)) ast.readExtraNode(node.data.extra, ast_mod.FormalParameterExtra.pattern) else return null,
        else => return null,
    };
    if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier) return null;
    return binding;
}

fn oldCarrierMatches(ast: *const ast_mod.Ast, owner: History.Owner, formals: []const Formal) bool {
    if (owner.tag != .formal_parameters or owner.node.isNone() or @backingInt(owner.node) >= ast.nodes.items.len) return false;
    const node = ast.getNode(owner.node);
    if (node.tag != .formal_parameters or node.data.list.len != formals.len or node.data.list.start > ast.extra_data.items.len or node.data.list.len > ast.extra_data.items.len - node.data.list.start) return false;
    for (formals, 0..) |formal, offset| {
        const binding = oldFormalBinding(ast, @fromBackingInt(ast.extra_data.items[node.data.list.start + offset])) orelse return false;
        if (binding != formal.binding) return false;
    }
    return true;
}

fn ownerAliases(a: std.mem.Allocator, editor: anytype, root_live: *const std.DynamicBitSet, n: ScopeId, p: ScopeId, name: NodeIndex, params: NodeIndex, formals: []const Formal) ![]const OwnerAlias {
    var result: std.ArrayList(OwnerAlias) = .empty;
    defer result.deinit(a);
    var entries = editor.scope_owner_map.iterator();
    while (entries.next()) |entry| {
        const scope: ScopeId = @fromBackingInt(entry.value_ptr.*);
        if (scope != n and (p.isNone() or scope != p)) continue;
        const index: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const owner = (History.Owner.capture(editor.ast, index) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidNode,
        }) orelse return error.InvalidNode;
        if (scope == n) {
            if (index != name or owner.tag != .binding_identifier) return error.InvalidScope;
        } else if (index == params or entry.key_ptr.* >= root_live.capacity() or root_live.isSet(entry.key_ptr.*) or !oldCarrierMatches(editor.ast, owner, formals)) return error.InvalidScope;
        try result.append(a, .{ .scope = scope, .owner = owner });
    }
    return try result.toOwnedSlice(a);
}

pub fn validateOwnerAliases(w: Witness, ast: *const ast_mod.Ast, live: *const std.DynamicBitSet, owners: *const std.AutoHashMapUnmanaged(u32, u32), published: bool) bool {
    for (w.owners, 0..) |alias, offset| {
        if (alias.scope != w.name_scope and (!w.retire_parameters or w.parameter_scope.isNone() or alias.scope != w.parameter_scope)) return false;
        const raw = @backingInt(alias.owner.node);
        if (alias.owner.node.isNone() or raw >= ast.nodes.items.len or raw >= live.capacity()) return false;
        const current = History.Owner.capture(ast, alias.owner.node) catch return false;
        if (current == null or !std.meta.eql(current.?, alias.owner)) return false;
        if (alias.scope == w.name_scope) {
            if (alias.owner.node != w.event.name or alias.owner.tag != .binding_identifier) return false;
        } else if (alias.owner.node == w.event.parameters or live.isSet(raw) or !oldCarrierMatches(ast, alias.owner, w.formals)) return false;
        if (published) {
            if (owners.contains(raw)) return false;
        } else if (owners.get(raw) != @as(?u32, @backingInt(alias.scope))) return false;
        for (w.owners[0..offset]) |previous| if (previous.owner.node == alias.owner.node) return false;
    }
    var current = owners.iterator();
    while (current.next()) |entry| if (entry.value_ptr.* == @backingInt(w.name_scope) or (w.retire_parameters and !w.parameter_scope.isNone() and entry.value_ptr.* == @backingInt(w.parameter_scope))) {
        if (published) return false;
        var found = false;
        for (w.owners) |alias| if (@backingInt(alias.owner.node) == entry.key_ptr.* and @backingInt(alias.scope) == entry.value_ptr.*) {
            found = true;
            break;
        };
        if (!found) return false;
    };
    return true;
}

// Initial Analyzer engines have no lowering receipt: their storage and
// origin are the same original function frame. Authenticate that birth from
// the sealed initial frame/owner edges, never from a later equal-shaped scope.
fn originalEngineBirth(editor: anytype, owner: NodeIndex, name_scope: ScopeId, body_scope: ScopeId, id: u32, before: symbol.Symbol) !bool {
    if (owner.isNone() or name_scope.isNone() or body_scope.isNone() or
        before.origin_scope != body_scope or before.scope_id != body_scope or
        !std.meta.eql(before.decl_flags, symbol.SymbolKind.parameter.declFlags()) or
        @backingInt(owner) >= editor.ast.nodes.items.len or
        editor.scope_owner_map.get(@backingInt(owner)) != @as(?u32, @backingInt(body_scope))) return false;
    const node = editor.ast.getNode(owner);
    if (node.tag != .function_expression or !editor.ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.flags) or
        !std.meta.eql(before.declaration_span, node.span)) return false;
    const name = editor.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
    if (name.isNone() or @backingInt(name) >= editor.symbol_ids.items.len) return false;
    const name_sid = editor.symbol_ids.items[@backingInt(name)] orelse return false;
    if (name_sid >= editor.symbols.items.len) return false;
    const name_symbol = editor.symbols.items[name_sid];
    if (name_symbol.scope_id != name_scope or name_symbol.origin_scope != name_scope or !name_symbol.kind.isFunctionLike() or
        editor.scope_maps.items[name_scope.toIndex()].count() != 1 or
        editor.scope_maps.items[name_scope.toIndex()].get(editor.ast.getText(editor.ast.getNode(name).data.string_ref)) != @as(?usize, name_sid)) return false;
    var name_declarations: usize = 0;
    for (editor.references.items) |row| if (@backingInt(row.symbol_id) == name_sid and row.flags.declare) {
        if (row.scope_id != name_scope or !row.node_index.isNone() or row.declaration_node_index != name or !std.meta.eql(row.flags, @as(symbol.ReferenceFlags, .{ .declare = true }))) return false;
        name_declarations += 1;
    };
    if (name_declarations != 1) return false;
    const name_owner = editor.scope_owner_map.get(@backingInt(name));
    if (name_owner != null and name_owner != @as(?u32, @backingInt(name_scope))) return false;
    const history = editor.scopeHistoryView();
    if (body_scope.toIndex() >= history.source_scopes.len or name_scope.toIndex() >= history.source_scopes.len or
        !History.sameFrame(history.source_scopes[body_scope.toIndex()], editor.scopes.items[body_scope.toIndex()]) or
        !History.sameFrame(history.source_scopes[name_scope.toIndex()], editor.scopes.items[name_scope.toIndex()]) or
        history.source_scopes[body_scope.toIndex()].kind != .function or
        history.source_scopes[body_scope.toIndex()].parent != name_scope or
        history.source_scopes[name_scope.toIndex()].kind != .block) return false;
    var index = try History.validateAndIndex(editor.allocator, editor.ast, editor.scopes.items, &editor.scope_owner_map, &history, null);
    defer index.deinit(editor.allocator);
    if (!index.valid) return false;
    const actual_owner = (History.Owner.capture(editor.ast, owner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    }) orelse return false;
    const actual_name = (History.Owner.capture(editor.ast, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    }) orelse return false;
    var initial_owner: ?History.Owner = null;
    var final_edges: History.SourceEdges = .{};
    var name_births: usize = 0;
    for (history.source_owners) |birth| {
        if (birth.scope == body_scope and birth.owner.tag == .function_expression) {
            if (initial_owner != null or !std.meta.eql(birth.owner.span, before.declaration_span)) return false;
            initial_owner = birth.owner;
            final_edges = birth.edges;
        }
        if (birth.owner.node == name) {
            if (birth.scope != name_scope or !std.meta.eql(birth.owner, actual_name)) return false;
            name_births += 1;
        }
    }
    var final_owner = initial_owner orelse return false;
    // Replay only the exact original function owner's registered transfers.
    // Current params/body may be new carriers; an actual owner event supplies
    // their edges instead of reinterpreting them as the initial birth.
    for (history.events) |event| {
        if (event.kind != .owner or event.scope != body_scope) continue;
        if (event.owner_before) |previous| if (previous.node == final_owner.node) {
            if (!std.meta.eql(previous, final_owner)) return false;
            const next = event.owner_after orelse return false;
            if (next.tag != .function_expression or !std.meta.eql(next.span, before.declaration_span)) return false;
            final_owner = next;
            final_edges = event.owner_edges;
        };
    }
    if (!std.meta.eql(final_owner, actual_owner) or
        final_edges.parameters != editor.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params) or
        final_edges.body != editor.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body)) return false;
    // Analyzer records the function owner at G; its NFE name is a binding
    // slot, not necessarily another scope-owner entry. Preserve that exact
    // initial/current owner representation instead of inventing a name owner.
    if (name_births != @as(usize, if (name_owner != null) 1 else 0) or
        editor.scope_maps.items[body_scope.toIndex()].get("arguments") != @as(?usize, id)) return false;
    var entries = editor.scope_maps.items[body_scope.toIndex()].iterator();
    while (entries.next()) |entry| if (entry.value_ptr.* == id and !std.mem.eql(u8, entry.key_ptr.*, "arguments")) return false;
    return true;
}

fn actualEngine(editor: anytype, body_scope: ScopeId, origins: *const std.AutoHashMapUnmanaged(u32, ScopeId), original_owner: NodeIndex, name_scope: ScopeId) !?Engine {
    var result: ?Engine = null;
    for (editor.symbols.items, 0..) |before, id| if (before.scope_id == body_scope and before.synthetic_kind == .implicit_arguments) {
        if (result != null or before.kind != .parameter or !std.mem.eql(u8, before.synthetic_name, "arguments")) return error.InvalidSymbol;
        if (origins.get(@intCast(id))) |origin| {
            // A present but conflicting lowering receipt must never fall back.
            if (origin != body_scope) return error.InvalidSymbol;
        } else if (!try originalEngineBirth(editor, original_owner, name_scope, body_scope, @intCast(id), before)) return error.InvalidSymbol;
        var declaration: ?Reference = null;
        for (editor.references.items) |row| if (@backingInt(row.symbol_id) == id and row.flags.declare) {
            if (declaration != null or row.scope_id != body_scope or !row.node_index.isNone() or !row.declaration_node_index.isNone() or !std.meta.eql(row.flags, @as(symbol.ReferenceFlags, .{ .declare = true }))) return error.InvalidSymbol;
            declaration = row;
        };
        result = .{ .symbol_id = @fromBackingInt(@as(u32, @intCast(id))), .before = before, .declaration = declaration orelse return error.ReferenceNotFound };
    };
    return result;
}

pub fn validateFormals(w: Witness, ast: *const ast_mod.Ast, symbols: []const symbol.Symbol, ids: []const ?u32, references: []const Reference) bool {
    const scope = if (!w.parameter_scope.isNone() and !w.retire_parameters) w.parameter_scope else w.body_scope;
    const params = w.event.parameters;
    if (params.isNone() or @backingInt(params) >= ast.nodes.items.len) return false;
    const node = ast.getNode(params);
    if (node.tag != .formal_parameters or node.data.list.len != w.formals.len or node.data.list.start > ast.extra_data.items.len or node.data.list.len > ast.extra_data.items.len - node.data.list.start) return false;
    for (w.formals, 0..) |formal, offset| {
        const binding = formalBinding(ast, @fromBackingInt(ast.extra_data.items[node.data.list.start + offset]), !w.parameter_scope.isNone() and !w.retire_parameters) orelse return false;
        const sid = @backingInt(formal.symbol_id);
        if (binding != formal.binding or @backingInt(binding) >= ids.len or ids[@backingInt(binding)] != @as(?u32, sid) or sid >= symbols.len or
            !sameName(ast.getNode(binding), formal.node) or formal.before.kind != .parameter or formal.before.scope_id != scope or formal.before.synthetic_kind == .implicit_arguments or
            !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(ast.getText(formal.node.data.string_ref), if (formal.before.synthetic_name.len != 0) formal.before.synthetic_name else ast.getText(formal.before.name))) return false;
        var before = formal.before;
        before.reference_count = symbols[sid].reference_count;
        before.write_count = symbols[sid].write_count;
        if (!@import("source_owned_retirement.zig").equalSymbol(before, symbols[sid])) return false;
        var declarations: usize = 0;
        for (references) |row| if (row.symbol_id == formal.symbol_id and row.flags.declare) {
            if (!std.meta.eql(row, formal.declaration)) return false;
            declarations += 1;
        };
        if (declarations != 1 or formal.declaration.scope_id != scope or formal.declaration.declaration_node_index != binding or !formal.declaration.node_index.isNone() or !std.meta.eql(formal.declaration.flags, @as(symbol.ReferenceFlags, .{ .declare = true }))) return false;
        for (w.formals[0..offset]) |previous| if (previous.binding == binding or previous.symbol_id == formal.symbol_id) return false;
    }
    var engines: usize = 0;
    for (symbols, 0..) |value, sid| if (value.scope_id == scope and value.synthetic_kind == .implicit_arguments) {
        const engine = w.engine orelse return false;
        if (@backingInt(engine.symbol_id) != sid or engine.before.kind != .parameter or engine.before.synthetic_kind != .implicit_arguments or !std.mem.eql(u8, engine.before.synthetic_name, "arguments") or engine.before.scope_id != scope) return false;
        var before = engine.before;
        before.reference_count = value.reference_count;
        before.write_count = value.write_count;
        if (!@import("source_owned_retirement.zig").equalSymbol(before, value)) return false;
        var declarations: usize = 0;
        for (references) |row| if (row.symbol_id == engine.symbol_id and row.flags.declare) {
            if (!std.meta.eql(row, engine.declaration)) return false;
            declarations += 1;
        };
        if (declarations != 1 or !engine.declaration.node_index.isNone() or !engine.declaration.declaration_node_index.isNone() or engine.declaration.scope_id != scope or !std.meta.eql(engine.declaration.flags, @as(symbol.ReferenceFlags, .{ .declare = true }))) return false;
        engines += 1;
    };
    return engines == @as(usize, if (w.engine == null) 0 else 1);
}

fn validScope(scopes: []const Scope, scope: ScopeId) bool {
    return !scope.isNone() and scope.toIndex() < scopes.len;
}

pub fn captureAll(a: std.mem.Allocator, editor: anytype, root: NodeIndex, origins: *const std.AutoHashMapUnmanaged(u32, ScopeId)) ![]const Source {
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, editor.ast, root);
    defer a.free(nodes);
    var live = try std.DynamicBitSet.initEmpty(a, editor.ast.nodes.items.len);
    defer live.deinit();
    for (nodes) |raw| live.set(raw);
    var result: std.ArrayList(Source) = .empty;
    errdefer {
        for (result.items) |source| {
            a.free(source.witness.formals);
            a.free(source.witness.owners);
        }
        result.deinit(a);
    }
    for (nodes) |raw| {
        const node = editor.ast.nodes.items[raw];
        if (node.tag != .function_expression or !editor.ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.flags)) continue;
        const name = editor.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone()) continue;
        if (@backingInt(name) >= editor.symbol_ids.items.len) return error.InvalidNode;
        const sid = editor.symbol_ids.items[@backingInt(name)] orelse return error.InvalidSymbol;
        if (sid >= editor.symbols.items.len) return error.InvalidSymbol;
        const before = editor.symbols.items[sid];
        if (before.reference_count != 0 or before.decl_flags.preserve_class_name) continue;
        const n = before.scope_id;
        const g: ScopeId = @fromBackingInt(editor.scope_owner_map.get(raw) orelse return error.InvalidScope);
        if (!validScope(editor.scopes.items, n) or !validScope(editor.scopes.items, g)) return error.InvalidScope;
        const name_frame = editor.scopes.items[n.toIndex()];
        const body_frame = editor.scopes.items[g.toIndex()];
        const params = editor.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
        const body = editor.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body);
        // A live parameter environment cannot be erased. Its ordinary name
        // elision remains a separate transaction rejection, never a fake frame.
        const p = if (body_frame.parent == n) ScopeId.none else body_frame.parent;
        if (!validScope(editor.scopes.items, name_frame.parent) or name_frame.kind != .block or body_frame.kind != .function or
            before.origin_scope != n or !before.kind.isFunctionLike() or before.isExported() or before.isSynthetic() or before.write_count != 0 or
            name_frame.blocksMangling() or body_frame.blocksMangling() or editor.scopes.items[name_frame.parent.toIndex()].blocksMangling() or
            editor.scope_maps.items[n.toIndex()].count() != 1 or name_frame.symbol_count != 1 or
            !sameName(editor.ast.getNode(name), .{ .tag = .binding_identifier, .span = before.declaration_span, .data = .{ .string_ref = before.name } })) continue;
        var parameter_frame: Scope = .{ .parent = .none, .kind = .function, .is_strict = false };
        var retire_parameters = false;
        if (!p.isNone()) {
            if (!validScope(editor.scopes.items, p)) continue;
            parameter_frame = editor.scopes.items[p.toIndex()];
            if (parameter_frame.kind != .function or parameter_frame.parent != n or parameter_frame.blocksMangling()) continue;
            retire_parameters = parameter_frame.symbol_count == 0 and editor.scope_maps.items[p.toIndex()].count() == 0;
            if (!retire_parameters and editor.scope_owner_map.get(@backingInt(params)) != @as(?u32, @backingInt(p))) return error.InvalidScope;
        }
        var declaration: ?Reference = null;
        for (editor.references.items) |row| if (@backingInt(row.symbol_id) == sid) {
            if (declaration != null or !row.flags.declare or row.flags.read or row.flags.write or row.scope_id != n or !row.node_index.isNone() or row.declaration_node_index != name) return error.InvalidSymbol;
            declaration = row;
        };
        if (declaration == null) return error.ReferenceNotFound;
        const formal_scope = if (!p.isNone() and !retire_parameters) p else g;
        const formals = (try actualFormals(a, editor, params, formal_scope, !p.isNone() and !retire_parameters)) orelse continue;
        errdefer a.free(formals);
        const engine = try actualEngine(editor, formal_scope, origins, if (p.isNone()) @fromBackingInt(raw) else .none, n);
        const owner_rows = try ownerAliases(a, editor, &live, n, if (retire_parameters) p else .none, name, params, formals);
        errdefer a.free(owner_rows);
        const event: Elision = .{ .owner = @fromBackingInt(raw), .owner_node = node, .name = name, .name_node = editor.ast.getNode(name), .symbol_id = @fromBackingInt(sid), .parameters = params, .body = body };
        try result.append(a, .{ .domain = editor.ast, .backing = editor.ast.source, .root = root, .before = before, .declaration = declaration.?, .witness = .{ .event = event, .name_scope = n, .parameter_scope = p, .retire_parameters = retire_parameters, .body_scope = g, .outer_scope = name_frame.parent, .name_frame = name_frame, .parameter_frame = parameter_frame, .body_frame = body_frame, .formals = formals, .engine = engine, .owners = owner_rows } });
    }
    return result.toOwnedSlice(a);
}

pub fn sameEvent(a: Elision, b: Elision) bool {
    return a.owner == b.owner and sameOwner(a.owner_node, b.owner_node) and a.name == b.name and sameName(a.name_node, b.name_node) and a.symbol_id == b.symbol_id and a.parameters == b.parameters and a.body == b.body;
}

pub fn validateState(retired: anytype, ast: *const ast_mod.Ast, live: *const std.DynamicBitSet, symbols: []const symbol.Symbol, ids: []const ?u32, scopes: []const Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), references: []const Reference) bool {
    const w = retired.function_name_elision orelse return false;
    const e = w.event;
    const sid = @backingInt(e.symbol_id);
    if (retired.reason != .elided_function_name or retired.symbol_id != e.symbol_id or sid >= symbols.len or
        retired.source_owner != e.owner or !sameOwner(retired.source_owner_node, e.owner_node) or retired.source_name != e.name or retired.source_name_symbol != e.symbol_id or
        retired.source_scope != w.body_scope or retired.closure_scope != w.name_scope or retired.closure_parent != w.outer_scope or retired.source_parent != w.outer_scope or
        retired.erased_import != null or retired.static_capture_alias != null or retired.declaration_node == null or !sameName(retired.declaration_node.?, e.name_node) or
        retired.before.scope_id != w.name_scope or retired.before.origin_scope != w.name_scope or !retired.before.kind.isFunctionLike() or retired.before.reference_count != 0 or retired.before.write_count != 0 or retired.before.isExported() or retired.before.isSynthetic()) return false;
    for ([_]NodeIndex{ e.owner, e.name, e.body }) |node| if (node.isNone() or @backingInt(node) >= ast.nodes.items.len or @backingInt(node) >= live.capacity()) return false;
    for ([_]ScopeId{ w.name_scope, w.body_scope, w.outer_scope }) |scope| if (!validScope(scopes, scope)) return false;
    if (!live.isSet(@backingInt(e.owner)) or !live.isSet(@backingInt(e.body)) or live.isSet(@backingInt(e.name)) or @backingInt(e.name) >= ids.len or ids[@backingInt(e.name)] != null) return false;
    const owner = ast.getNode(e.owner);
    if (!sameOwner(owner, e.owner_node) or !ast.hasExtra(owner.data.extra, ast_mod.FunctionExtra.flags) or !ast.readExtraNode(owner.data.extra, ast_mod.FunctionExtra.name).isNone() or
        ast.readExtraNode(owner.data.extra, ast_mod.FunctionExtra.params) != e.parameters or ast.readExtraNode(owner.data.extra, ast_mod.FunctionExtra.body) != e.body or
        owners.get(@backingInt(e.owner)) != @as(?u32, @backingInt(w.body_scope)) or (owners.get(@backingInt(e.body)) != null and owners.get(@backingInt(e.body)) != @as(?u32, @backingInt(w.body_scope))) or !sameName(ast.getNode(e.name), e.name_node)) return false;
    var expected_g = w.body_frame;
    if (w.parameter_scope.isNone() or w.retire_parameters) expected_g.parent = w.outer_scope;
    if (!History.sameFrame(scopes[w.body_scope.toIndex()], expected_g) or w.body_frame.kind != .function or w.name_frame.kind != .block or w.name_frame.parent != w.outer_scope or
        !History.sameFrame(scopes[w.name_scope.toIndex()], w.name_frame) or scopes[w.name_scope.toIndex()].symbol_count != 0 or w.name_frame.symbol_count != 1 or
        w.name_frame.blocksMangling() or w.body_frame.blocksMangling() or scopes[w.outer_scope.toIndex()].blocksMangling()) return false;
    if (!validateFormals(w, ast, symbols, ids, references) or !validateOwnerAliases(w, ast, live, owners, true)) return false;
    const formal_scope = if (!w.parameter_scope.isNone() and !w.retire_parameters) w.parameter_scope else w.body_scope;
    if (owners.get(@backingInt(e.parameters))) |owner_scope| if (owner_scope != @backingInt(formal_scope)) return false;
    if (w.parameter_scope.isNone()) {
        if (w.retire_parameters or w.body_frame.parent != w.name_scope) return false;
    } else {
        if (!validScope(scopes, w.parameter_scope) or w.body_frame.parent != w.parameter_scope or w.parameter_frame.kind != .function or w.parameter_frame.parent != w.name_scope or w.parameter_frame.blocksMangling()) return false;
        var expected_p = w.parameter_frame;
        if (w.retire_parameters) {
            if (w.parameter_frame.symbol_count != 0 or scopes[w.parameter_scope.toIndex()].symbol_count != 0) return false;
        } else {
            expected_p.parent = w.outer_scope;
            if (owners.get(@backingInt(e.parameters)) != @as(?u32, @backingInt(w.parameter_scope)) or !live.isSet(@backingInt(e.parameters))) return false;
        }
        if (!History.sameFrame(scopes[w.parameter_scope.toIndex()], expected_p)) return false;
    }
    return @import("source_owned_retirement.zig").equalSymbol(retired.before, symbols[sid]) and retired.declaration.symbol_id == e.symbol_id and retired.declaration.scope_id == w.name_scope and
        retired.declaration.node_index.isNone() and retired.declaration.declaration_node_index == e.name and std.meta.eql(retired.declaration.flags, @as(symbol.ReferenceFlags, .{ .declare = true })) and
        std.meta.eql(retired.before.name, e.name_node.data.string_ref) and std.meta.eql(retired.before.declaration_span, e.name_node.span);
}

test "original Analyzer arguments engine requires exact initial G name-owner birth" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "(function unused(p){const local=arguments[0];return local});console.log(42);");
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var editor = try analyzer.beginEdit();
    var owner: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .function_expression) {
        owner = @fromBackingInt(@as(u32, @intCast(raw)));
    };
    try std.testing.expect(!owner.isNone());
    const g: ScopeId = @fromBackingInt(editor.scope_owner_map.get(@backingInt(owner)).?);
    const n = editor.scopes.items[g.toIndex()].parent;
    const id: u32 = @intCast(editor.scope_maps.items[g.toIndex()].get("arguments").?);
    var origins: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty;
    const positive = (try actualEngine(&editor, g, &origins, owner, n)).?;
    try std.testing.expectEqual(id, @backingInt(positive.symbol_id));
    try std.testing.expect(positive.before.origin_scope == g and positive.declaration.declaration_node_index.isNone());

    // A real but conflicting lowering receipt is authoritative rejection.
    try origins.put(a, id, n);
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    _ = origins.remove(id);
    const before = editor.symbols.items[id];
    editor.symbols.items[id].origin_scope = n;
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    editor.symbols.items[id] = before;
    editor.symbols.items[id].declaration_span.end += 1;
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    editor.symbols.items[id] = before;
    const map = &editor.scope_maps.items[g.toIndex()];
    _ = map.remove("arguments");
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    try map.put(a, "arguments", id + 1);
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    try map.put(a, "arguments", id);
    const parent = editor.scopes.items[g.toIndex()].parent;
    editor.scopes.items[g.toIndex()].parent = editor.scopes.items[n.toIndex()].parent;
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    editor.scopes.items[g.toIndex()].parent = parent;
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, .none, n));
    const rows = editor.references.items.len;
    try editor.references.append(a, positive.declaration);
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    editor.references.shrinkRetainingCapacity(rows);
    var source_owner_index: ?usize = null;
    for (editor.scope_history.source_owners, 0..) |birth, index| if (birth.owner.node == owner) {
        source_owner_index = index;
    };
    const birth_index = source_owner_index orelse return error.MissingActualFunctionBirth;
    const birth = editor.scope_history.source_owners[birth_index];
    editor.scope_history.source_owners[birth_index].scope = n;
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    editor.scope_history.source_owners[birth_index] = birth;
    const source_frame = editor.scope_history.source_scopes[g.toIndex()];
    editor.scope_history.source_scopes[g.toIndex()].parent = editor.scopes.items[n.toIndex()].parent;
    try std.testing.expectError(error.InvalidSymbol, actualEngine(&editor, g, &origins, owner, n));
    editor.scope_history.source_scopes[g.toIndex()] = source_frame;
    try std.testing.expect((try actualEngine(&editor, g, &origins, owner, n)) != null);
}
