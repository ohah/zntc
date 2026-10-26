//! Native arguments declarations have no AST binding leaf. Their existing
//! typed SID and ScopeId select an actual live function owner, never a name.
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
    var wanted: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer wanted.deinit(allocator);
    for (references) |reference| {
        if (!reference.flags.declare or !reference.declaration_node_index.isNone()) continue;
        const sid = @backingInt(reference.symbol_id);
        if (sid >= symbols.len) return null;
        const symbol = symbols[sid];
        if (symbol.synthetic_kind != .implicit_arguments) continue;
        if (symbol.kind != .parameter or !reference.node_index.isNone() or
            !std.meta.eql(reference.flags, @as(symbol_mod.ReferenceFlags, .{ .declare = true })) or
            symbol.scope_id != reference.scope_id or symbol.scope_id.isNone() or
            symbol.scope_id.toIndex() >= scopes.len or scopes[symbol.scope_id.toIndex()].kind != .function)
            return null;
        const slot = try wanted.getOrPut(allocator, @backingInt(symbol.scope_id));
        // One native engine slot and one declaration row per function.
        if (slot.found_existing) return null;
        slot.value_ptr.* = sid;
    }
    if (wanted.count() == 0) {
        published = true;
        return result;
    }
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .implicit_arguments) continue;
        if (wanted.get(@backingInt(symbol.scope_id))) |selected| {
            if (selected != sid) return null;
        }
    }

    // Parameters are a separate engine environment only when this exact
    // current parameter node belongs to one ordinary function (never an arrow).
    var parameter_functions: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parameter_functions.deinit(allocator);
    for (ast.nodes.items, 0..) |node, raw| {
        if (raw >= contexts.len or contexts[raw] == null or !ordinaryFunction(node.tag)) continue;
        if (!ast.hasExtra(node.data.extra, 1)) return null;
        const params = ast.readExtraNode(node.data.extra, 1);
        if (params.isNone()) continue;
        if (@backingInt(params) >= ast.nodes.items.len or ast.getNode(params).tag != .formal_parameters) return null;
        const slot = try parameter_functions.getOrPut(allocator, @backingInt(params));
        if (slot.found_existing and slot.value_ptr.* != raw) return null;
        slot.value_ptr.* = @intCast(raw);
    }
    const Owner = struct { node: u32, context: Context };
    var actual: std.AutoHashMapUnmanaged(u32, Owner) = .empty;
    defer actual.deinit(allocator);
    var iterator = owners.iterator();
    while (iterator.next()) |entry| {
        const scope = entry.value_ptr.*;
        if (!wanted.contains(scope)) continue;
        const raw = entry.key_ptr.*;
        if (raw >= contexts.len or raw >= ast.nodes.items.len) return null;
        const context = contexts[raw] orelse continue;
        const node = ast.nodes.items[raw];
        if (node.tag == .formal_parameters) {
            const function = parameter_functions.get(raw) orelse return null;
            const body_scope = owners.get(function) orelse return null;
            if (body_scope >= scopes.len or body_scope == scope or
                scopes[body_scope].kind != .function or @backingInt(scopes[body_scope].parent) != scope)
                return null;
        } else if (!ordinaryFunction(node.tag)) return null;
        const slot = try actual.getOrPut(allocator, scope);
        if (slot.found_existing and slot.value_ptr.node != raw) return null;
        slot.value_ptr.* = .{ .node = raw, .context = context };
    }
    for (references) |reference| {
        if (!reference.flags.declare or !reference.declaration_node_index.isNone()) continue;
        const sid = @backingInt(reference.symbol_id);
        if (symbols[sid].synthetic_kind != .implicit_arguments) continue;
        const owner = actual.get(@backingInt(reference.scope_id)) orelse return null;
        try result.put(allocator, sid, owner.context);
    }
    published = true;
    return result;
}
