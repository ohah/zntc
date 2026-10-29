//! Exact structural proofs for semantic scope-owner metadata.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const scope_mod = @import("scope.zig");

/// Prove that a class static-block var scope has exactly its static-block node
/// and body block as owners, and that the static block belongs to the class
/// whose class-body scope is the scope's parent. The scope kind is intentionally
/// not checked here so callers can also reject a poisoned scope-kind mutation.
pub fn exactClassStaticBlockScopeOwners(
    ast: *const ast_mod.Ast,
    scopes: []const scope_mod.Scope,
    scope_owner_map: *const std.AutoHashMapUnmanaged(u32, u32),
    reachable: *const std.DynamicBitSet,
    scope_raw: u32,
) bool {
    if (scope_raw >= scopes.len) return false;
    const scope = scopes[scope_raw];
    if (!scope.is_strict or scope.parent.isNone() or scope.parent.toIndex() >= scopes.len or
        scopes[scope.parent.toIndex()].kind != .class_body) return false;

    var static_owner: ?u32 = null;
    var body_owner: ?u32 = null;
    var owner_count: usize = 0;
    var owners = scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != scope_raw) continue;
        const owner_raw = entry.key_ptr.*;
        if (owner_raw >= ast.nodes.items.len or owner_raw >= reachable.capacity() or
            !reachable.isSet(owner_raw)) return false;
        switch (ast.nodes.items[owner_raw].tag) {
            .static_block => {
                if (static_owner != null) return false;
                static_owner = owner_raw;
            },
            .block_statement => {
                if (body_owner != null) return false;
                body_owner = owner_raw;
            },
            else => return false,
        }
        owner_count += 1;
    }
    if (owner_count != 2) return false;
    const static_raw = static_owner orelse return false;
    const block_raw = body_owner orelse return false;
    const static_body = ast.nodes.items[static_raw].data.unary.operand;
    if (static_body.isNone() or @backingInt(static_body) != block_raw) return false;

    const parent_scope_raw: u32 = @intCast(scope.parent.toIndex());
    var matching_class_owners: usize = 0;
    for (ast.nodes.items, 0..) |class_node, raw| {
        if (class_node.tag != .class_declaration and class_node.tag != .class_expression) continue;
        if (raw >= reachable.capacity() or !reachable.isSet(raw)) continue;
        const owner_scope = scope_owner_map.get(@intCast(raw)) orelse continue;
        if (owner_scope != parent_scope_raw) continue;

        const extra = class_node.data.extra;
        if (extra > ast.extra_data.items.len or
            ast.extra_data.items.len - extra <= ast_mod.ClassExtra.body) return false;
        const class_body: ast_mod.NodeIndex = @fromBackingInt(
            @intCast(ast.extra_data.items[extra + ast_mod.ClassExtra.body]),
        );
        if (class_body.isNone() or @backingInt(class_body) >= ast.nodes.items.len or
            @backingInt(class_body) >= reachable.capacity() or !reachable.isSet(@backingInt(class_body))) return false;
        const class_body_node = ast.nodes.items[@backingInt(class_body)];
        if (class_body_node.tag != .class_body) return false;
        const members = class_body_node.data.list;
        if (members.start > ast.extra_data.items.len or
            members.len > ast.extra_data.items.len - members.start) return false;
        var occurrences: usize = 0;
        for (ast.extra_data.items[members.start..][0..members.len]) |member_raw| {
            if (member_raw == static_raw) occurrences += 1;
        }
        if (occurrences == 1) matching_class_owners += 1;
    }
    return matching_class_owners == 1;
}
