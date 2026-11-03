//! Statement coordinates from current AST containment; binding and scope IDs are inputs.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const SemanticReference = @import("../semantic/symbol.zig").Reference;
pub const Context = @import("../semantic/statement_coordinates.zig").Context;
pub const collect = @import("../semantic/statement_coordinates.zig").collect;

/// Path splits keep every source binding/reference identity, but can move
/// statement buckets. Native class-self and anonymous default-facade
/// declarations and native/IIFE entry roles use their exact producers instead of a leaf.
pub fn project(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    semantic: anytype,
) !?[]SemanticReference {
    const contexts = collect(allocator, ast, root) catch return null;
    const updated = try allocator.dupe(SemanticReference, semantic.references);
    var entry_contexts = (try @import("implicit_arguments_statement_owner.zig").collect(
        allocator,
        ast,
        contexts,
        semantic.symbols.items,
        semantic.scopes,
        &semantic.scope_owner_map,
        semantic.references,
    )) orelse return null;
    defer entry_contexts.deinit(allocator);
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
                symbol.scope_id.toIndex() >= semantic.scopes.len) return null;
            if (semantic.scopes[symbol.scope_id.toIndex()].kind != .class_body) return null;
            // The class-self table retains the initial source role; the actual
            // current class node owns that same exact ScopeId after AST copies.
            slot.* = class_scope_contexts.get(@backingInt(symbol.scope_id)) orelse return null;
        }
        // A class expression can lose its source-side class_self_symbol_map
        // key when lowering relocates that entry to the generated wrapper
        // binding. The original inner class declaration row remains
        // anchorless, but its exact class-body ScopeId still has one live AST
        // owner. Project that row by ScopeId even when the sidecar no longer
        // names the original class node.
        var anchorless = anchorless_contexts.iterator();
        while (anchorless.next()) |entry| {
            const slot = entry.value_ptr;
            if (slot.* != null) continue;
            const sid = entry.key_ptr.*;
            if (sid >= semantic.symbols.items.len) continue;
            const symbol = semantic.symbols.items[sid];
            if (symbol.kind != .class_decl or symbol.scope_id.isNone() or
                symbol.scope_id.toIndex() >= semantic.scopes.len or
                semantic.scopes[symbol.scope_id.toIndex()].kind != .class_body) continue;
            slot.* = class_scope_contexts.get(@backingInt(symbol.scope_id)) orelse return null;
        }
        var implicit = entry_contexts.iterator();
        while (implicit.next()) |entry| {
            const slot = anchorless_contexts.getPtr(entry.key_ptr.*) orelse return null;
            if (slot.*) |previous| if (!std.meta.eql(previous, entry.value_ptr.*)) return null;
            slot.* = entry.value_ptr.*;
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

test "anchorless class self follows the exact current class body owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, "class Named {}");
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var source_class: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) {
            source_class = @intCast(raw);
            break;
        }
    }
    const source_class_raw = source_class orelse return error.MissingSourceClass;
    const source_class_node = parser.ast.nodes.items[source_class_raw];
    const source_name_raw = parser.ast.extra_data.items[source_class_node.data.extra + ast_mod.ClassExtra.name];
    const outer_sid = analyzer.symbol_ids.items[source_name_raw] orelse return error.MissingOuterClassSymbol;
    const inner_sid = analyzer.class_self_symbol_map.get(source_class_raw) orelse return error.MissingInnerClassSymbol;
    try std.testing.expect(outer_sid != inner_sid);

    const source_name_node = parser.ast.nodes.items[source_name_raw];
    const output_name = try parser.ast.addLeafNode(
        .binding_identifier,
        source_name_node.span,
        .{ .string_ref = source_name_node.data.string_ref },
    );
    var class_extra = try allocator.dupe(u32, parser.ast.extra_data.items[source_class_node.data.extra..][0..8]);
    class_extra[ast_mod.ClassExtra.name] = @backingInt(output_name);
    const class_extra_start = try parser.ast.addExtras(class_extra);
    const output_class = try parser.ast.addExtraNode(.class_declaration, source_class_node.span, class_extra_start);
    const output_class_raw = @backingInt(output_class);
    const source_root_span = parser.ast.getNode(root).span;
    const output_body = try parser.ast.addNodeList(&.{output_class});
    const output_root = try parser.ast.addListNode(.program, source_root_span, output_body);
    parser.ast.transformed_root = output_root;

    var symbol_ids = try allocator.alloc(?u32, parser.ast.nodes.items.len);
    @memset(symbol_ids, null);
    @memcpy(symbol_ids[0..analyzer.symbol_ids.items.len], analyzer.symbol_ids.items);
    symbol_ids[@backingInt(output_name)] = outer_sid;
    const references = try allocator.dupe(@TypeOf(analyzer.references.items[0]), analyzer.references.items);
    var reanchored_outer = false;
    for (references) |*reference| {
        if (reference.flags.declare and @backingInt(reference.symbol_id) == outer_sid) {
            reference.declaration_node_index = output_name;
            reanchored_outer = true;
        }
    }
    try std.testing.expect(reanchored_outer);

    const class_scope = analyzer.scope_owner_map.get(source_class_raw) orelse return error.MissingClassScopeOwner;
    var scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try scope_owner_map.put(allocator, output_class_raw, class_scope);
    var semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_owner_map = scope_owner_map,
        .class_self_symbol_map = @TypeOf(analyzer.class_self_symbol_map).empty,
        .symbol_ids = symbol_ids,
        .references = references,
    };

    const projected = (try project(allocator, &parser.ast, output_root, &semantic)) orelse return error.ClassSelfProjectionRejected;
    try std.testing.expectEqual(references.len, projected.len);
    var found_inner_declaration = false;
    for (projected) |reference| {
        if (!reference.flags.declare or @backingInt(reference.symbol_id) != inner_sid) continue;
        found_inner_declaration = true;
        try std.testing.expectEqual(@as(u32, 0), reference.stmt_idx);
        try std.testing.expectEqual(@as(u32, 0), reference.scope_stmt_idx);
    }
    try std.testing.expect(found_inner_declaration);

    // A missing output class-scope owner must still fail closed.
    semantic.scope_owner_map = .empty;
    try std.testing.expect((try project(allocator, &parser.ast, output_root, &semantic)) == null);
}

/// Statement metadata may change; SymbolId/ScopeId and source read identities do not.
pub fn refresh(module: *@import("module.zig").Module, shaker: ?*@import("tree_shaker.zig").TreeShaker, newly_live: []const NodeIndex) !void {
    const a = module.parse_arena.?.allocator();
    const ast = &module.ast.?;
    const sem = &module.semantic.?;
    const rebuilt = try @import("stmt_info.zig").buildFromSemantic(a, ast, sem.symbols.items, sem.scopes, sem.symbol_ids, sem.references, &sem.unresolved_references, false, false) orelse return;
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
