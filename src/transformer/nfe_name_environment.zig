//! Read-only classification of a named function expression's lexical self name.
//! This environment survives ES5 output; it is not a block declaration hoisted
//! into its parent var environment. No spelling participates in classification.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const scope = @import("../semantic/scope.zig");
const symbol = @import("../semantic/symbol.zig");

pub const Input = struct {
    source: *const ast.Ast,
    source_node_count: u32,
    symbols: []const symbol.Symbol,
    scopes: []const scope.Scope,
    symbol_ids: []const ?u32,
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const symbol.Reference,
};

pub const Set = struct {
    input: Input,
    ids: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        self.ids.deinit(allocator);
    }

    pub fn contains(self: *const Set, source: ?*const ast.Ast, symbols: []const symbol.Symbol, scopes: []const scope.Scope, references: []const symbol.Reference, sid: u32) bool {
        if (source != self.input.source or symbols.ptr != self.input.symbols.ptr or symbols.len != self.input.symbols.len or
            scopes.ptr != self.input.scopes.ptr or scopes.len != self.input.scopes.len or
            references.ptr != self.input.references.ptr or references.len != self.input.references.len) return false;
        return self.ids.contains(sid);
    }
};

fn validScope(in: Input, id: scope.ScopeId) bool {
    return !id.isNone() and id.toIndex() < in.scopes.len;
}

/// Unknown or inconsistent source roles retain the existing rename path.
/// A valid name edge and its exact declaration row must agree with the actual
/// function owner and, when present, the separate formal-parameter owner.
const Role = struct { name: ast.NodeIndex, sid: u32, scope_id: scope.ScopeId };

fn structuralRole(in: Input, function: ast.NodeIndex, parent_validity: ?[]const u8) ?Role {
    if (in.source_node_count > in.source.nodes.items.len or function.isNone() or
        @backingInt(function) >= in.source_node_count) return null;
    const node = in.source.getNode(function);
    if (node.tag != .function_expression or !in.source.hasExtra(node.data.extra, ast.FunctionExtra.return_type)) return null;
    const name = in.source.readExtraNode(node.data.extra, ast.FunctionExtra.name);
    const params = in.source.readExtraNode(node.data.extra, ast.FunctionExtra.params);
    const body = in.source.readExtraNode(node.data.extra, ast.FunctionExtra.body);
    if (name.isNone() or params.isNone() or body.isNone() or @backingInt(name) >= in.source_node_count or
        @backingInt(params) >= in.source_node_count or @backingInt(body) >= in.source_node_count or @backingInt(name) >= in.symbol_ids.len) return null;
    if (in.source.getNode(name).tag != .binding_identifier or in.source.getNode(params).tag != .formal_parameters or
        in.source.getNode(body).tag != .block_statement) return null;
    const sid = in.symbol_ids[@backingInt(name)] orelse return null;
    if (sid >= in.symbols.len) return null;
    const binding = in.symbols[sid];
    const flags = in.source.readExtra(node.data.extra, ast.FunctionExtra.flags);
    const async_fn = flags & ast.FunctionFlags.is_async != 0;
    const generator = flags & ast.FunctionFlags.is_generator != 0;
    const expected_kind: symbol.SymbolKind = if (async_fn and generator) .async_generator_decl else if (async_fn) .async_function_decl else if (generator) .generator_decl else .function_decl;
    if (binding.kind != expected_kind or binding.synthetic_kind != null or !validScope(in, binding.scope_id)) return null;
    const name_scope = binding.scope_id;
    if (in.scopes[name_scope.toIndex()].kind != .block or !validScope(in, in.scopes[name_scope.toIndex()].parent)) return null;
    const body_raw = in.owners.get(@backingInt(function)) orelse return null;
    const body_scope: scope.ScopeId = @fromBackingInt(body_raw);
    if (!validScope(in, body_scope) or in.scopes[body_raw].kind != .function or body_scope == name_scope) return null;
    if (in.owners.get(@backingInt(params))) |params_raw| {
        const params_scope: scope.ScopeId = @fromBackingInt(params_raw);
        if (!validScope(in, params_scope) or in.scopes[params_raw].kind != .function or params_scope == body_scope or
            params_scope == name_scope or in.scopes[body_raw].parent != params_scope or in.scopes[params_raw].parent != name_scope) return null;
    } else if (in.scopes[body_raw].parent != name_scope) return null;
    // Parent validity is memoized once by collect; a one-role diagnostic
    // validates the same graph without inferring ownership from ancestors.
    if (parent_validity) |validity| {
        if (validity[name_scope.toIndex()] != 2) return null;
    } else {
        var parent = in.scopes[name_scope.toIndex()].parent;
        var hops: usize = 0;
        while (!parent.isNone()) : (hops += 1) {
            if (hops >= in.scopes.len or !validScope(in, parent) or parent == name_scope or parent == body_scope) return null;
            parent = in.scopes[parent.toIndex()].parent;
        }
    }
    return .{ .name = name, .sid = sid, .scope_id = name_scope };
}

fn agrees(role: Role, ref: symbol.Reference) bool {
    return ref.flags.declare and !ref.flags.read and !ref.flags.write and !ref.flags.type_context and
        !ref.symbol_id.isNone() and @backingInt(ref.symbol_id) == role.sid and ref.scope_id == role.scope_id;
}

/// Diagnostic entry point; production collect indexes declarations once.
pub fn selfBinding(in: Input, function: ast.NodeIndex) ?u32 {
    const role = structuralRole(in, function, null) orelse return null;
    var edges: usize = 0;
    for (0..in.source_node_count) |raw| {
        if (attachedSelfId(in, @fromBackingInt(@as(u32, @intCast(raw)))) == role.sid) edges += 1;
    }
    if (edges != 1) return null;
    var declarations: usize = 0;
    for (in.references) |ref| {
        if (ref.declaration_node_index != role.name) continue;
        if (!agrees(role, ref)) return null;
        declarations += 1;
    }
    return if (declarations == 1) role.sid else null;
}

fn attachedSelfId(in: Input, function: ast.NodeIndex) ?u32 {
    const node = in.source.getNode(function);
    if (node.tag != .function_expression or !in.source.hasExtra(node.data.extra, ast.FunctionExtra.name)) return null;
    const name = in.source.readExtraNode(node.data.extra, ast.FunctionExtra.name);
    if (name.isNone() or @backingInt(name) >= in.source_node_count or @backingInt(name) >= in.symbol_ids.len) return null;
    return in.symbol_ids[@backingInt(name)];
}

fn parentValidity(allocator: std.mem.Allocator, scopes: []const scope.Scope) std.mem.Allocator.Error![]u8 {
    const state = try allocator.alloc(u8, scopes.len);
    errdefer allocator.free(state);
    @memset(state, 0);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(allocator);
    for (0..scopes.len) |raw| {
        if (state[raw] != 0) continue;
        stack.clearRetainingCapacity();
        var current: scope.ScopeId = @fromBackingInt(@as(u32, @intCast(raw)));
        const valid = while (!current.isNone()) {
            const index = current.toIndex();
            if (index >= scopes.len) break false;
            switch (state[index]) {
                1, 3 => break false,
                2 => break true,
                else => {},
            }
            state[index] = 1;
            try stack.append(allocator, index);
            current = scopes[index].parent;
        } else true;
        for (stack.items) |index| state[index] = if (valid) 2 else 3;
    }
    return state;
}

pub fn collect(allocator: std.mem.Allocator, in: Input) std.mem.Allocator.Error!Set {
    var set: Set = .{ .input = in };
    errdefer set.deinit(allocator);
    if (in.source_node_count > in.source.nodes.items.len) return set;
    const validity = try parentValidity(allocator, in.scopes);
    defer allocator.free(validity);
    var sid_edges: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer sid_edges.deinit(allocator);
    for (0..in.source_node_count) |raw| {
        const sid = attachedSelfId(in, @fromBackingInt(@as(u32, @intCast(raw)))) orelse continue;
        const edge = try sid_edges.getOrPut(allocator, sid);
        if (!edge.found_existing) edge.value_ptr.* = 0;
        edge.value_ptr.* += 1;
    }
    const Candidate = struct { role: Role, declarations: usize = 0, valid: bool = true };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    var by_name_node: std.AutoHashMapUnmanaged(ast.NodeIndex, usize) = .empty;
    defer by_name_node.deinit(allocator);
    for (0..in.source_node_count) |raw| {
        const role = structuralRole(in, @fromBackingInt(@as(u32, @intCast(raw))), validity) orelse continue;
        if (sid_edges.get(role.sid) != 1) continue;
        if (by_name_node.get(role.name)) |previous| {
            candidates.items[previous].valid = false;
            continue;
        }
        try by_name_node.put(allocator, role.name, candidates.items.len);
        try candidates.append(allocator, .{ .role = role });
    }
    for (in.references) |ref| {
        const index = by_name_node.get(ref.declaration_node_index) orelse continue;
        const candidate = &candidates.items[index];
        candidate.declarations += 1;
        if (!agrees(candidate.role, ref)) candidate.valid = false;
    }
    for (candidates.items) |candidate| {
        if (candidate.valid and candidate.declarations == 1) try set.ids.put(allocator, candidate.role.sid, {});
    }
    return set;
}
