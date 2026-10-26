//! Clone a runtime fragment inside one semantic owner. Owned scopes/bindings
//! receive fresh IDs; references leaving the fragment keep their exact IDs.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("scope.zig").ScopeId;
const symbol = @import("symbol.zig");
const SymbolId = symbol.SymbolId;
const Reference = symbol.Reference;
const Editor = @import("editor.zig").SemanticEditor;
pub const Error = @import("editor.zig").Error || error{ UnsupportedRuntimeLayout, InvalidCloneOwnership };

pub const Result = struct {
    roots: []NodeIndex,
    nodes: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty,
    scopes: std.AutoHashMapUnmanaged(u32, ScopeId) = .empty,
    symbols: std.AutoHashMapUnmanaged(u32, SymbolId) = .empty,
    from: ScopeId,
    to: ScopeId,

    pub fn scope(self: *const Result, original: ScopeId) ScopeId {
        return self.scopes.get(@backingInt(original)) orelse if (original == self.from) self.to else original;
    }
    pub fn sid(self: *const Result, original: SymbolId) SymbolId {
        return self.symbols.get(@backingInt(original)) orelse original;
    }
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.roots);
        self.nodes.deinit(allocator);
        self.scopes.deinit(allocator);
        self.symbols.deinit(allocator);
    }
};

fn cloneList(allocator: std.mem.Allocator, ast: *Ast, map: *std.AutoHashMapUnmanaged(u32, NodeIndex), start: u32, len: u32) Error!ast_mod.NodeList {
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return error.InvalidNode;
    const nodes = try allocator.alloc(NodeIndex, len);
    defer allocator.free(nodes);
    for (nodes, 0..) |*node, index| node.* = try cloneNode(allocator, ast, map, ast.readExtraNode(start, @intCast(index)));
    return ast.addNodeList(nodes);
}

fn cloneNode(allocator: std.mem.Allocator, ast: *Ast, map: *std.AutoHashMapUnmanaged(u32, NodeIndex), original: NodeIndex) Error!NodeIndex {
    if (original.isNone()) return original;
    const raw = @backingInt(original);
    if (raw >= ast.nodes.items.len) return error.InvalidNode;
    if (map.get(raw)) |cloned| return cloned;
    var node = ast.getNode(original);
    const cloned = try ast.addNode(node);
    try map.put(allocator, raw, cloned);
    switch (node.tag.dataKind()) {
        .leaf => {},
        .unary => node.data.unary.operand = try cloneNode(allocator, ast, map, node.data.unary.operand),
        .binary => {
            node.data.binary.left = try cloneNode(allocator, ast, map, node.data.binary.left);
            node.data.binary.right = try cloneNode(allocator, ast, map, node.data.binary.right);
        },
        .ternary => {
            node.data.ternary.a = try cloneNode(allocator, ast, map, node.data.ternary.a);
            node.data.ternary.b = try cloneNode(allocator, ast, map, node.data.ternary.b);
            node.data.ternary.c = try cloneNode(allocator, ast, map, node.data.ternary.c);
        },
        .list => node.data.list = try cloneList(allocator, ast, map, node.data.list.start, node.data.list.len),
        .extra => {
            const words = node.tag.runtimeExtraWords() orelse return error.UnsupportedRuntimeLayout;
            const base = node.data.extra;
            if (base > ast.extra_data.items.len or words > ast.extra_data.items.len - base) return error.InvalidNode;
            const payload = try allocator.dupe(u32, ast.extra_data.items[base..][0..words]);
            defer allocator.free(payload);
            for (node.tag.extraChildOffsets()) |offset| payload[offset] = @backingInt(try cloneNode(allocator, ast, map, @fromBackingInt(payload[offset])));
            for (node.tag.extraListOffsets()) |offset| {
                const list = try cloneList(allocator, ast, map, payload[offset[0]], payload[offset[1]]);
                payload[offset[0]] = list.start;
                payload[offset[1]] = list.len;
            }
            node.data.extra = try ast.addExtras(payload);
        },
    }
    ast.nodes.items[@backingInt(cloned)] = node;
    return cloned;
}

fn cloneScope(allocator: std.mem.Allocator, editor: *Editor, result: *Result, owned: *const std.AutoHashMapUnmanaged(u32, u32), original: ScopeId, depth: usize) Error!ScopeId {
    if (result.scopes.get(@backingInt(original))) |existing| return existing;
    if (depth > owned.count()) return error.InvalidScope;
    const owner = owned.get(@backingInt(original)) orelse return result.scope(original);
    if (original.isNone() or original.toIndex() >= editor.scopes.items.len) return error.InvalidScope;
    const source = editor.scopes.items[original.toIndex()];
    const parent = if (owned.contains(@backingInt(source.parent)))
        try cloneScope(allocator, editor, result, owned, source.parent, depth + 1)
    else if (source.parent == result.from)
        result.to
    else
        return error.InvalidCloneOwnership;
    const cloned = try editor.addScope(parent, if (owner == @backingInt(NodeIndex.none)) .none else result.nodes.get(owner) orelse return error.InvalidNode, source.kind, source.is_strict);
    editor.scopes.items[cloned.toIndex()].subtree_has_direct_eval = source.subtree_has_direct_eval;
    editor.scopes.items[cloned.toIndex()].subtree_has_with = source.subtree_has_with;
    try result.scopes.put(allocator, @backingInt(original), cloned);
    return cloned;
}

fn valueReference(flags: symbol.ReferenceFlags) bool {
    return !flags.declare and !flags.type_context and !flags.value_as_type;
}

pub fn cloneAst(allocator: std.mem.Allocator, ast: *Ast, roots: []const NodeIndex, from: ScopeId, to: ScopeId) Error!Result {
    var result = Result{ .roots = try allocator.alloc(NodeIndex, roots.len), .from = from, .to = to };
    errdefer result.deinit(allocator);
    for (roots, result.roots) |root, *output| output.* = try cloneNode(allocator, ast, &result.nodes, root);
    return result;
}

/// `owners` and `implicit_symbols` come from exact source owner/role maps,
/// never identifier spelling. The original fragment must not move until all
/// requested clones have been made.
pub fn clone(allocator: std.mem.Allocator, ast: *Ast, editor: *Editor, roots: []const NodeIndex, owners: *const std.AutoHashMapUnmanaged(u32, u32), lexical_name_scopes: []const ScopeId, implicit_symbols: []const SymbolId, from: ScopeId, to: ScopeId) Error!Result {
    if (from.isNone() or to.isNone() or from.toIndex() >= editor.scopes.items.len or to.toIndex() >= editor.scopes.items.len) return error.InvalidScope;
    var result = try cloneAst(allocator, ast, roots, from, to);
    errdefer result.deinit(allocator);
    const old_ref_count = editor.references.items.len;
    const old_slot_count = editor.symbol_ids.items.len;
    var owned: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owned.deinit(allocator);
    var owner_iter = owners.iterator();
    while (owner_iter.next()) |entry| {
        if (!result.nodes.contains(entry.key_ptr.*) or entry.value_ptr.* == @backingInt(from)) continue;
        try owned.put(allocator, entry.value_ptr.*, entry.key_ptr.*);
    }
    for (lexical_name_scopes) |id| {
        if (id.isNone() or id.toIndex() >= editor.scopes.items.len or editor.scopes.items[id.toIndex()].parent != from or editor.scopes.items[id.toIndex()].kind != .block) return error.InvalidCloneOwnership;
        try owned.put(allocator, @backingInt(id), @backingInt(NodeIndex.none));
    }
    var scope_iter = owned.keyIterator();
    while (scope_iter.next()) |id| _ = try cloneScope(allocator, editor, &result, &owned, @fromBackingInt(id.*), 0);
    owner_iter = owners.iterator();
    while (owner_iter.next()) |entry| {
        if (result.nodes.get(entry.key_ptr.*)) |node| if (result.scopes.get(entry.value_ptr.*)) |scope_id| {
            try editor.scope_owner_map.put(allocator, @backingInt(node), @backingInt(scope_id));
        };
    }
    var selected: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer selected.deinit(allocator);
    var nodes = result.nodes.keyIterator();
    while (nodes.next()) |raw| {
        if (raw.* >= editor.symbol_ids.items.len) continue;
        if (editor.symbol_ids.items[raw.*]) |id| {
            if (owned.contains(@backingInt(editor.symbols.items[id].scope_id))) try selected.put(allocator, id, {});
        }
    }
    for (implicit_symbols) |id| if (owned.contains(@backingInt(editor.symbols.items[@backingInt(id)].scope_id))) try selected.put(allocator, @backingInt(id), {});
    // Count source rows once for all selected identities. A large initializer
    // must not rescan the entire module for each local binding it owns.
    const Counts = struct { value: u32 = 0, writes: u32 = 0 };
    var counts: std.AutoHashMapUnmanaged(u32, Counts) = .empty;
    defer counts.deinit(allocator);
    for (editor.references.items[0..old_ref_count]) |row| {
        const id = @backingInt(row.symbol_id);
        if (!selected.contains(id) or !valueReference(row.flags)) continue;
        const entry = try counts.getOrPut(allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.value += 1;
        if (row.flags.write) entry.value_ptr.writes += 1;
    }
    var selected_iter = selected.keyIterator();
    while (selected_iter.next()) |old_id| {
        const source = editor.symbols.items[old_id.*];
        var copied = source;
        copied.scope_id = result.scope(source.scope_id);
        copied.origin_scope = result.scope(source.origin_scope);
        // Numeric/string fact tables are owned by the old SID. The cloned AST
        // remains available to normal fact producers; do not transplant them.
        copied.const_kind = .none;
        const source_counts = counts.get(old_id.*) orelse Counts{};
        const explicit = source_counts.value;
        const writes = source_counts.writes;
        if (source.reference_count < explicit or source.write_count < writes) return error.InvalidSymbol;
        copied.reference_count -= explicit;
        copied.write_count -= writes;
        const id: SymbolId = @fromBackingInt(@as(u32, @intCast(editor.symbols.items.len)));
        try editor.symbols.append(allocator, copied);
        editor.scopes.items[copied.scope_id.toIndex()].symbol_count +|= 1;
        try result.symbols.put(allocator, old_id.*, id);
    }
    var symbols = result.symbols.iterator();
    while (symbols.next()) |entry| {
        const copied = &editor.symbols.items[@backingInt(entry.value_ptr.*)];
        if (copied.synthetic_owner_id) |id| copied.synthetic_owner_id = result.sid(id);
        copied.annex_b_alias.variable = result.sid(copied.annex_b_alias.variable);
        copied.parameter_copy.parameter_source = result.sid(copied.parameter_copy.parameter_source);
    }
    var scopes = result.scopes.iterator();
    while (scopes.next()) |entry| {
        var names = editor.scope_maps.items[entry.key_ptr.*].iterator();
        while (names.next()) |name| {
            if (result.symbols.get(@intCast(name.value_ptr.*))) |id| try editor.scope_maps.items[entry.value_ptr.toIndex()].put(allocator, name.key_ptr.*, @backingInt(id));
        }
    }
    try editor.symbol_ids.resize(allocator, ast.nodes.items.len);
    @memset(editor.symbol_ids.items[old_slot_count..], null);
    var mapped_nodes = result.nodes.iterator();
    while (mapped_nodes.next()) |entry| {
        const original = entry.key_ptr.*;
        const cloned = @backingInt(entry.value_ptr.*);
        editor.symbol_ids.items[cloned] = if (original < old_slot_count) if (editor.symbol_ids.items[original]) |id| @backingInt(result.sid(@fromBackingInt(id))) else null else null;
    }
    // Snapshot rows, since adding references can reallocate the editor list.
    const source_rows = try allocator.dupe(Reference, editor.references.items[0..old_ref_count]);
    defer allocator.free(source_rows);
    for (source_rows) |row| {
        if (row.flags.declare) {
            const id = result.symbols.get(@backingInt(row.symbol_id)) orelse continue;
            const anchor = result.nodes.get(@backingInt(row.declaration_node_index)) orelse continue;
            var copied = row;
            copied.symbol_id = id;
            copied.scope_id = result.scope(row.scope_id);
            copied.declaration_node_index = anchor;
            copied.stmt_idx = Reference.NO_STMT;
            copied.scope_stmt_idx = Reference.NO_STMT;
            try editor.references.append(allocator, copied);
            editor.reference_index_built = false;
        } else if (result.nodes.get(@backingInt(row.node_index))) |node| {
            try editor.addCopiedReference(node, result.sid(row.symbol_id), result.scope(row.scope_id), row.flags, Reference.NO_STMT, Reference.NO_STMT);
        }
    }
    // Actual cloned binding nodes are declaration creators even when the
    // original lightweight analysis did not request declaration anchors.
    mapped_nodes = result.nodes.iterator();
    while (mapped_nodes.next()) |entry| {
        const node = entry.value_ptr.*;
        if (ast.getNode(node).tag != .binding_identifier) continue;
        const id = editor.symbol_ids.items[@backingInt(node)] orelse return error.InvalidSymbol;
        if (!result.symbols.contains(editor.symbol_ids.items[entry.key_ptr.*] orelse return error.InvalidSymbol)) return error.InvalidCloneOwnership;
        try editor.ensureDeclarationAtNode(@fromBackingInt(id), editor.symbols.items[id].scope_id, node);
    }
    for (implicit_symbols) |old_id| if (result.symbols.get(@backingInt(old_id))) |id| {
        try editor.ensureDeclaration(id, editor.symbols.items[@backingInt(id)].scope_id);
    };
    return result;
}
