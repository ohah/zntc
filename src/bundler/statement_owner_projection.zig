//! Statement coordinates from current AST containment; binding and scope IDs are inputs.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ast_walk = @import("../parser/ast_walk.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const SemanticReference = @import("../semantic/symbol.zig").Reference;
pub const Context = struct {
    stmt_idx: u32 = SemanticReference.NO_STMT,
    scope_stmt_idx: u32 = SemanticReference.NO_STMT,
};

const MinifiedStatementFrame = struct {
    node: ast_mod.NodeIndex,
    context: Context,
};

/// Recompute the statement coordinates consumed by tree shaking and the
/// emitter's dead-store pass, while keeping every existing SymbolId and
/// ScopeId. These coordinates are derived from current AST statement lists;
/// inability to map a graph row exactly makes retention ineligible.
pub fn collect(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
) ![]?Context {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return error.InvalidRoot;
    const contexts = try allocator.alloc(?Context, ast.nodes.items.len);
    @memset(contexts, null);
    var stack: std.ArrayListUnmanaged(MinifiedStatementFrame) = .empty;
    try stack.append(allocator, .{ .node = root, .context = .{} });

    while (stack.pop()) |frame| {
        if (frame.node.isNone()) continue;
        const raw: usize = @backingInt(frame.node);
        if (raw >= ast.nodes.items.len) return error.InvalidStatementNode;
        if (contexts[raw]) |existing| {
            if (!std.meta.eql(existing, frame.context)) return error.AmbiguousStatementContext;
            continue;
        }
        contexts[raw] = frame.context;
        const node = ast.nodes.items[raw];
        if (node.tag == .program or node.tag == .block_statement) {
            const list = node.data.list;
            const start: usize = list.start;
            const len: usize = list.len;
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start)
                return error.InvalidStatementList;
            for (ast.extra_data.items[start .. start + len], 0..) |child_raw, index| {
                const child: ast_mod.NodeIndex = @fromBackingInt(child_raw);
                var context = frame.context;
                if (node.tag == .program) context.stmt_idx = @intCast(index);
                context.scope_stmt_idx = @intCast(index);
                try stack.append(allocator, .{ .node = child, .context = context });
            }
            continue;
        }

        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            try stack.append(allocator, .{ .node = child, .context = frame.context });
        }
    }
    return contexts;
}

/// Path splits keep every source binding/reference identity, but can move
/// statement buckets. Native class-self and anonymous default-facade
/// declarations use their exact initial-producer roles instead of a leaf.
pub fn project(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    semantic: *const ModuleSemanticData,
) !?[]SemanticReference {
    const contexts = collect(allocator, ast, root) catch return null;
    const updated = try allocator.dupe(SemanticReference, semantic.references);
    var anchorless_contexts: std.AutoHashMapUnmanaged(u32, ?Context) = .empty;
    defer anchorless_contexts.deinit(allocator);
    for (updated) |reference| {
        if (reference.flags.declare and reference.declaration_node_index.isNone())
            try anchorless_contexts.put(allocator, @backingInt(reference.symbol_id), null);
    }
    if (anchorless_contexts.count() != 0) {
        var facade_owners: std.AutoHashMapUnmanaged(u32, ast_mod.NodeIndex) = .empty;
        defer facade_owners.deinit(allocator);
        for (ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .export_default_declaration) continue;
            const context = contexts[raw] orelse continue;
            const sid = (try @import("default_facade_identity.zig").symbolAt(ast, @fromBackingInt(@as(u32, @intCast(raw))), semantic.symbol_ids, semantic.symbols.items)) orelse continue;
            const slot = anchorless_contexts.getPtr(sid) orelse continue;
            const owner = try facade_owners.getOrPut(allocator, sid);
            const owner_node: ast_mod.NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
            if (owner.found_existing and owner.value_ptr.* != owner_node) return null;
            owner.value_ptr.* = owner_node;
            if (slot.*) |previous| if (!std.meta.eql(previous, context)) return null;
            slot.* = context;
        }
        var class_scope_contexts: std.AutoHashMapUnmanaged(u32, Context) = .empty;
        defer class_scope_contexts.deinit(allocator);
        var owners = semantic.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            const raw = entry.key_ptr.*;
            if (raw >= contexts.len) return null;
            const context = contexts[raw] orelse continue;
            const tag = ast.nodes.items[raw].tag;
            if (tag != .class_declaration and tag != .class_expression) continue;
            const slot = try class_scope_contexts.getOrPut(allocator, entry.value_ptr.*);
            if (slot.found_existing and !std.meta.eql(slot.value_ptr.*, context)) return null;
            slot.value_ptr.* = context;
        }
        var classes = semantic.class_self_symbol_map.valueIterator();
        while (classes.next()) |sid| {
            const slot = anchorless_contexts.getPtr(sid.*) orelse continue;
            if (sid.* >= semantic.symbols.items.len) return null;
            const symbol = semantic.symbols.items[sid.*];
            if (symbol.kind != .class_decl or symbol.scope_id.isNone() or
                symbol.scope_id.toIndex() >= semantic.scopes.len or
                semantic.scopes[symbol.scope_id.toIndex()].kind != .class_body) return null;
            // The class-self table retains the initial source role; the actual
            // current class node owns that same exact ScopeId after AST copies.
            slot.* = class_scope_contexts.get(@backingInt(symbol.scope_id)) orelse return null;
        }
    }
    for (updated) |*reference| {
        const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        const context = if (node.isNone() and reference.flags.declare)
            (anchorless_contexts.get(@backingInt(reference.symbol_id)) orelse return null) orelse return null
        else if (!node.isNone() and @backingInt(node) < contexts.len)
            contexts[@backingInt(node)] orelse return null
        else
            return null;
        if (node.isNone() and reference.flags.declare and semantic.symbols.items[@backingInt(reference.symbol_id)].decl_flags.is_default_export and
            reference.scope_id.toIndex() != 0) return null;
        reference.stmt_idx = context.stmt_idx;
        reference.scope_stmt_idx = context.scope_stmt_idx;
    }
    return updated;
}

/// Statement metadata may change; SymbolId/ScopeId and source read identities do not.
pub fn refresh(module: *@import("module.zig").Module, shaker: ?*@import("tree_shaker.zig").TreeShaker, newly_live: []const NodeIndex) !void {
    const a = module.parse_arena.?.allocator();
    const ast = &module.ast.?;
    const sem = &module.semantic.?;
    const rebuilt = try @import("stmt_info.zig").buildFromSemantic(a, ast, sem.symbols.items, sem.scopes, sem.references, &sem.unresolved_references, false, false) orelse return;
    module.prebuilt_stmt_info = rebuilt;
    const s = shaker orelse return;
    const index = module.index.toU32();
    if (index >= s.module_stmt_infos.len or index >= s.reachable_stmts.len) return error.InvalidGuardedStatementState;
    const old = s.module_stmt_infos[index] orelse return; // Preserve opaque wrapped-module policy.
    var alive: std.AutoHashMapUnmanaged(u32, void) = .empty;
    if (s.reachable_stmts[index]) |reachable| {
        for (old.stmts, 0..) |statement, i| if (i < reachable.capacity() and reachable.isSet(i)) try alive.put(a, statement.node_idx, {});
    }
    for (newly_live) |statement| try alive.put(a, @backingInt(statement), {});
    var replacement = try std.DynamicBitSet.initEmpty(s.allocator, rebuilt.stmts.len);
    errdefer replacement.deinit();
    for (rebuilt.stmts, 0..) |statement, i| if (alive.contains(statement.node_idx)) replacement.set(i);
    if (s.prebuilt_mask) |*mask| {
        if (!mask.isSet(index)) {
            var owned = old;
            owned.deinit();
        }
        mask.set(index);
    } else return error.InvalidGuardedStatementState;
    if (s.reachable_stmts[index]) |*previous| previous.deinit();
    s.reachable_stmts[index] = replacement;
    s.module_stmt_infos[index] = rebuilt;
    module.reachable_stmts = &s.reachable_stmts[index].?;
    module.symbol_to_stmt = rebuilt.symbol_to_stmt;
}
