const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub fn buildParentMap(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
) !std.AutoHashMapUnmanaged(u32, u32) {
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    errdefer parents.deinit(allocator);
    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable.deinit(allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.pop()) |node| {
        if (node.isNone() or @backingInt(node) >= ast.nodes.items.len) continue;
        const raw = @backingInt(node);
        const gop = try reachable.getOrPut(allocator, raw);
        if (gop.found_existing) continue;
        var children = ast_walk.children(ast, ast.getNode(node));
        while (children.next()) |child| {
            if (child.isNone() or @backingInt(child) >= ast.nodes.items.len) continue;
            const parent_gop = try parents.getOrPut(allocator, @backingInt(child));
            if (!parent_gop.found_existing) parent_gop.value_ptr.* = raw;
            try stack.append(allocator, child);
        }
    }
    return parents;
}

fn containsExtraListNode(ast: *const Ast, start: u32, len: u32, child: u32) bool {
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return false;
    for (ast.extra_data.items[start .. start + len]) |raw| {
        if (raw == child) return true;
    }
    return false;
}

fn skipsOwner(ast: *const Ast, parent_raw: u32, child_raw: u32) bool {
    const parent = ast.nodes.items[parent_raw];
    switch (parent.tag) {
        .ts_enum_declaration => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .switch_statement => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .method_definition => {
            const extra = parent.data.extra;
            if (extra + ast_mod.MethodExtra.deco_len >= ast.extra_data.items.len) return false;
            if (ast.extra_data.items[extra + ast_mod.MethodExtra.key] == child_raw) return true;
            return containsExtraListNode(
                ast,
                ast.extra_data.items[extra + ast_mod.MethodExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.MethodExtra.deco_len],
                child_raw,
            );
        },
        .class_declaration, .class_expression => {
            const extra = parent.data.extra;
            if (extra + ast_mod.ClassExtra.deco_len >= ast.extra_data.items.len) return false;
            return containsExtraListNode(
                ast,
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_len],
                child_raw,
            );
        },
        else => return false,
    }
}

pub fn expectedScope(
    ast: *const Ast,
    root: NodeIndex,
    parents: *const std.AutoHashMapUnmanaged(u32, u32),
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    node: u32,
) ?ScopeId {
    var child = node;
    var hops: usize = 0;
    while (hops <= ast.nodes.items.len) : (hops += 1) {
        const parent = parents.get(child) orelse return if (scope_owner_map.get(child)) |scope|
            @fromBackingInt(@intCast(scope))
        else
            null;
        if (!skipsOwner(ast, parent, child)) {
            if (scope_owner_map.get(parent)) |scope| return @fromBackingInt(@intCast(scope));
        }
        child = parent;
        if (child == @backingInt(root)) return if (scope_owner_map.get(child)) |scope|
            @fromBackingInt(@intCast(scope))
        else
            null;
    }
    return null;
}

/// Independently ascend the emitted AST parent map to its actual statement lists.
pub fn expectedStatementCoordinates(ast: *const Ast, parents: *const std.AutoHashMapUnmanaged(u32, u32), node: u32) ?struct { stmt_idx: u32, scope_stmt_idx: u32 } {
    var child = node;
    var top: ?u32 = null;
    var local: ?u32 = null;
    var hops: usize = 0;
    while (parents.get(child)) |parent| : (hops += 1) {
        if (hops >= ast.nodes.items.len or parent >= ast.nodes.items.len) return null;
        const owner = ast.nodes.items[parent];
        if (owner.tag == .program or owner.tag == .block_statement) {
            const list = owner.data.list;
            const index = std.mem.indexOfScalar(u32, ast.extra_data.items[list.start .. list.start + list.len], child) orelse return null;
            if (local == null) local = @intCast(index);
            if (owner.tag == .program) top = @intCast(index);
        }
        child = parent;
    }
    return .{ .stmt_idx = top orelse return null, .scope_stmt_idx = local orelse return null };
}
