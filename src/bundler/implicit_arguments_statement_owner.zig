//! Native engine and TypeScript IIFE entry declarations have no binding leaf.
//! Existing typed SIDs and ScopeIds select their current owner, never a name.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const symbol_mod = @import("../semantic/symbol.zig");
const scope_mod = @import("../semantic/scope.zig");
const Context = @import("../semantic/statement_coordinates.zig").Context;
pub const Contexts = std.AutoHashMapUnmanaged(u32, Context);

fn ordinaryFunction(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .function_declaration, .function_expression, .function, .method_definition => true,
        else => false,
    };
}

const Role = enum { engine, namespace_parameter, enum_parameter };

fn roleOf(symbol: symbol_mod.Symbol) ?Role {
    return switch (symbol.synthetic_kind orelse return null) {
        .implicit_arguments => .engine,
        .namespace_iife_parameter => .namespace_parameter,
        .enum_iife_parameter => .enum_parameter,
        else => null,
    };
}

const Slots = struct {
    engine: ?u32 = null,
    namespace_parameter: ?u32 = null,
    enum_parameter: ?u32 = null,
    engine_symbol: ?u32 = null,

    fn slot(self: *Slots, role: Role) *?u32 {
        return switch (role) {
            .engine => &self.engine,
            .namespace_parameter => &self.namespace_parameter,
            .enum_parameter => &self.enum_parameter,
        };
    }
};

/// Coordinate-only projection for declared native entry roles. A TypeScript
/// creator has one primary node and at most its canonical body/prelude alias;
/// the alias never selects a different binding or replaces the primary owner.
pub fn collect(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    contexts: []const ?Context,
    symbols: []const symbol_mod.Symbol,
    scopes: []const scope_mod.Scope,
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const symbol_mod.Reference,
) !?Contexts {
    var result: Contexts = .empty;
    var published = false;
    defer if (!published) result.deinit(allocator);
    var wanted: std.AutoHashMapUnmanaged(u32, Slots) = .empty;
    defer wanted.deinit(allocator);
    for (references) |reference| {
        if (!reference.flags.declare or !reference.declaration_node_index.isNone()) continue;
        const sid = @backingInt(reference.symbol_id);
        if (sid >= symbols.len) return null;
        const symbol = symbols[sid];
        const role = roleOf(symbol) orelse continue;
        if (symbol.kind != .parameter or !reference.node_index.isNone() or
            !std.meta.eql(reference.flags, @as(symbol_mod.ReferenceFlags, .{ .declare = true })) or
            symbol.scope_id != reference.scope_id or symbol.scope_id.isNone() or
            symbol.scope_id.toIndex() >= scopes.len or scopes[symbol.scope_id.toIndex()].kind != .function)
            return null;
        const group = try wanted.getOrPut(allocator, @backingInt(symbol.scope_id));
        if (!group.found_existing) group.value_ptr.* = .{};
        const slot = group.value_ptr.slot(role);
        if (slot.* != null) return null;
        slot.* = sid;
    }
    // A reachable non-ambient TS creator is itself the authority that an
    // IIFE entry parameter must exist, even if its role and declaration rows
    // were both lost. Erased owners have no current statement context.
    for (contexts, 0..) |context, raw| {
        if (context == null or raw >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[raw];
        if (node.tag == .ts_module_declaration) {
            if (node.data.binary.flags != 0) continue;
        } else if (node.tag == .ts_enum_declaration) {
            if (!ast.hasExtra(node.data.extra, ast_mod.EnumExtra.flags)) return null;
            if (ast.readExtra(node.data.extra, ast_mod.EnumExtra.flags) & 2 != 0) continue;
        } else continue;
        const scope = owners.get(@intCast(raw)) orelse return null;
        const group = try wanted.getOrPut(allocator, scope);
        if (!group.found_existing) group.value_ptr.* = .{};
    }
    if (wanted.count() == 0) {
        published = true;
        return result;
    }
    for (symbols, 0..) |symbol, sid| {
        const role = roleOf(symbol) orelse continue;
        const group = wanted.getPtr(@backingInt(symbol.scope_id)) orelse continue;
        if (role == .engine) {
            if (group.engine_symbol != null) return null;
            group.engine_symbol = @intCast(sid);
            if (symbol.kind == .variable_var) {
                // A real source var can share native arguments storage. It
                // keeps its explicit binding anchor and the ordinary path.
                if (group.engine != null) return null;
                var anchored = false;
                for (references) |reference| {
                    if (@backingInt(reference.symbol_id) != sid or !reference.flags.declare or
                        reference.scope_id != symbol.scope_id or reference.declaration_node_index.isNone()) continue;
                    const raw = @backingInt(reference.declaration_node_index);
                    if (raw >= contexts.len or raw >= ast.nodes.items.len or contexts[raw] == null or
                        ast.nodes.items[raw].tag != .binding_identifier) return null;
                    anchored = true;
                }
                if (!anchored) return null;
                continue;
            }
        }
        if (symbol.kind != .parameter or group.slot(role).* != @as(u32, @intCast(sid))) return null;
    }

    var parameter_functions: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parameter_functions.deinit(allocator);
    for (ast.nodes.items, 0..) |node, raw| {
        if (raw >= contexts.len or contexts[raw] == null or !ordinaryFunction(node.tag)) continue;
        if (!ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.params)) return null;
        const params = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
        if (params.isNone()) continue;
        if (@backingInt(params) >= ast.nodes.items.len or ast.getNode(params).tag != .formal_parameters) return null;
        const slot = try parameter_functions.getOrPut(allocator, @backingInt(params));
        if (slot.found_existing and slot.value_ptr.* != raw) return null;
        slot.value_ptr.* = @intCast(raw);
    }
    const Owner = struct { node: u32, context: Context, alias: ?u32 = null };
    var actual: std.AutoHashMapUnmanaged(u32, Owner) = .empty;
    defer actual.deinit(allocator);
    const Alias = struct { node: u32, scope: u32 };
    var aliases: std.ArrayList(Alias) = .empty;
    defer aliases.deinit(allocator);
    var iterator = owners.iterator();
    while (iterator.next()) |entry| {
        const scope = entry.value_ptr.*;
        const slots = wanted.get(scope) orelse continue;
        const raw = entry.key_ptr.*;
        if (raw >= contexts.len or raw >= ast.nodes.items.len) return null;
        const context = contexts[raw] orelse continue;
        const node = ast.nodes.items[raw];
        if (node.tag == .block_statement or node.tag == .ts_module_block) {
            try aliases.append(allocator, .{ .node = raw, .scope = scope });
            continue;
        }
        var alias: ?u32 = null;
        if (node.tag == .ts_module_declaration) {
            if (node.data.binary.flags != 0 or slots.namespace_parameter == null or slots.enum_parameter != null)
                return null;
            const body = node.data.binary.right;
            if (body.isNone() or @backingInt(body) >= ast.nodes.items.len) return null;
            const body_tag = ast.getNode(body).tag;
            if (body_tag == .block_statement or body_tag == .ts_module_block) {
                alias = @backingInt(body);
            } else if (body_tag != .ts_module_declaration) return null;
        } else if (node.tag == .ts_enum_declaration) {
            if (slots.enum_parameter == null or slots.namespace_parameter != null or
                !ast.hasExtra(node.data.extra, ast_mod.EnumExtra.runtime_prelude) or
                ast.readExtra(node.data.extra, ast_mod.EnumExtra.flags) & 2 != 0) return null;
            const prelude = ast.readExtraNode(node.data.extra, ast_mod.EnumExtra.runtime_prelude);
            if (!prelude.isNone()) {
                if (@backingInt(prelude) >= ast.nodes.items.len or ast.getNode(prelude).tag != .block_statement or
                    owners.get(@backingInt(prelude)) != scope) return null;
                alias = @backingInt(prelude);
            }
        } else {
            if (slots.namespace_parameter != null or slots.enum_parameter != null) return null;
            if (node.tag == .formal_parameters) {
                const function = parameter_functions.get(raw) orelse return null;
                const body_scope = owners.get(function) orelse return null;
                if (body_scope >= scopes.len or body_scope == scope or
                    scopes[body_scope].kind != .function or @backingInt(scopes[body_scope].parent) != scope)
                    return null;
            } else if (!ordinaryFunction(node.tag)) return null;
        }
        if (alias) |body| {
            if (owners.get(body)) |body_scope| if (body_scope != scope) return null;
        }
        const slot = try actual.getOrPut(allocator, scope);
        if (slot.found_existing and slot.value_ptr.node != raw) return null;
        slot.value_ptr.* = .{ .node = raw, .context = context, .alias = alias };
    }
    for (aliases.items) |alias| {
        const owner = actual.get(alias.scope) orelse return null;
        if (owner.alias != alias.node) return null;
    }
    for (references) |reference| {
        if (!reference.flags.declare or !reference.declaration_node_index.isNone()) continue;
        const sid = @backingInt(reference.symbol_id);
        if (roleOf(symbols[sid]) == null) continue;
        const owner = actual.get(@backingInt(reference.scope_id)) orelse return null;
        try result.put(allocator, sid, owner.context);
    }
    published = true;
    return result;
}
