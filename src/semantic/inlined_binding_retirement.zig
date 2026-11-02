//! A single-use local declaration consumed by the actual minifier inline event.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const sym = @import("symbol.zig");
const scope = @import("scope.zig");
const H = @import("scope_frame_history.zig");
pub const Witness = struct {
    declarator: ast.NodeIndex,
    declarator_node: ast.Node,
    initializer: ast.NodeIndex,
    read: ast.NodeIndex,
    read_node: ast.Node,
    read_reference: sym.Reference,
    statement_kind: u32,
    source_epoch: u32,
    source_frame: scope.Scope,
    read_frame: scope.Scope,
};
pub const Event = struct {
    read_origin: sym.Reference,
    read_step_count: usize,
    domain: *const ast.Ast,
    symbol_id: sym.SymbolId,
    before: sym.Symbol,
    declaration: sym.Reference,
    statement: ast.NodeIndex,
    statement_node: ast.Node,
    binding: ast.NodeIndex,
    binding_node: ast.Node,
    initializer_node: ast.Node,
    wrapped_initializer: bool,
    witness: Witness,
};
fn validNode(tree: *const ast.Ast, index: ast.NodeIndex) bool {
    return !index.isNone() and @backingInt(index) < tree.nodes.items.len;
}
fn sameFrame(a: scope.Scope, b: scope.Scope) bool {
    var x = a;
    var y = b;
    x.symbol_count = 0;
    y.symbol_count = 0;
    return std.meta.eql(x, y);
}
fn identifierText(tree: *const ast.Ast, ref: @import("../lexer/token.zig").Span) ?[]const u8 {
    const table = ast.Ast.STRING_TABLE_BIT;
    if (ref.start & table != ref.end & table) return null;
    const start = ref.start & ~table;
    const end = ref.end & ~table;
    const bytes = if (ref.start & table != 0) tree.string_table.items else tree.source;
    if (start >= end or end > bytes.len) return null;
    return bytes[start..end];
}
fn sameIdentifierValue(allocator: std.mem.Allocator, tree: *const ast.Ast, left: ast.Node, right: ast.Node) std.mem.Allocator.Error!bool {
    const a = identifierText(tree, left.data.string_ref) orelse return false;
    const b = identifierText(tree, right.data.string_ref) orelse return false;
    if (std.mem.eql(u8, a, b)) return true;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const decoded_a = try Scanner.decodeIdentifierEscapesAlloc(allocator, a);
    defer if (decoded_a.ptr != a.ptr) allocator.free(decoded_a);
    const decoded_b = try Scanner.decodeIdentifierEscapesAlloc(allocator, b);
    defer if (decoded_b.ptr != b.ptr) allocator.free(decoded_b);
    return std.mem.eql(u8, decoded_a, decoded_b);
}
pub fn validate(
    allocator: std.mem.Allocator,
    w: @import("source_owned_retirement.zig").Witness,
    tree: *const ast.Ast,
    live: *const std.DynamicBitSet,
    rows: []const sym.Symbol,
    ids: []const ?u32,
    scopes: []const scope.Scope,
    maps: []const std.StringHashMapUnmanaged(usize),
    refs: []const sym.Reference,
    roots: @import("source_owned_retirement.zig").Roots,
    index: ?*const H.Index,
) std.mem.Allocator.Error!bool {
    const payload = w.inlined_binding orelse return false;
    const history = index orelse return false;
    const sid = @backingInt(w.symbol_id);
    if (!history.valid or w.reason != .inlined_local_binding or sid >= rows.len or
        w.source_name_symbol != w.symbol_id or !w.closure_scope.isNone() or !w.closure_parent.isNone() or
        w.erased_import != null or w.static_capture_alias != null or w.function_name_elision != null or w.enum_environment != null or w.dropped_statement != null or
        !validNode(tree, w.source_owner) or !validNode(tree, w.source_name) or !validNode(tree, payload.declarator) or
        !validNode(tree, payload.initializer) or !validNode(tree, payload.read)) return false;
    const before = w.before;
    if ((before.kind != .variable_let and before.kind != .variable_const) or before.isExported() or
        before.reference_count == 0 or before.write_count != 0 or before.scope_id != w.source_scope or
        !before.annex_b_alias.variable.isNone() or before.annex_b_alias.state != .native or !before.parameter_copy.parameter_source.isNone() or
        w.source_scope.isNone() or w.source_scope.toIndex() >= scopes.len or w.source_scope.toIndex() >= maps.len or
        payload.source_frame.blocksMangling() or payload.read_frame.blocksMangling() or
        w.source_parent != payload.source_frame.parent) return false;
    const initial_frame = history.frameAt(w.source_scope, payload.source_epoch) orelse return false;
    const read_ref = payload.read_reference;
    if (read_ref.scope_id.isNone() or read_ref.scope_id.toIndex() >= scopes.len or
        read_ref.symbol_id != w.symbol_id or read_ref.node_index != payload.read or !read_ref.declaration_node_index.isNone() or
        !std.meta.eql(read_ref.flags, @as(sym.ReferenceFlags, .{ .read = true }))) return false;
    const initial_read_frame = history.frameAt(read_ref.scope_id, payload.source_epoch) orelse return false;
    if (!sameFrame(initial_frame, payload.source_frame) or !sameFrame(initial_read_frame, payload.read_frame)) return false;
    const binding = w.declaration_node orelse return false;
    if (binding.tag != .binding_identifier or payload.read_node.tag != .identifier_reference or
        !std.meta.eql(binding.span, before.name) or !try sameIdentifierValue(allocator, tree, binding, payload.read_node) or
        w.declaration.symbol_id != w.symbol_id or w.declaration.scope_id != w.source_scope or
        !w.declaration.node_index.isNone() or w.declaration.declaration_node_index != w.source_name or
        !std.meta.eql(w.declaration.flags, @as(sym.ReferenceFlags, .{ .declare = true }))) return false;
    if (w.source_owner_node.tag != .variable_declaration or payload.declarator_node.tag != .variable_declarator or
        !tree.hasExtra(w.source_owner_node.data.extra, 2) or !tree.hasExtra(payload.declarator_node.data.extra, 2)) return false;
    const se = w.source_owner_node.data.extra;
    const de = payload.declarator_node.data.extra;
    const start = tree.extra_data.items[se + 1];
    if (tree.extra_data.items[se] != payload.statement_kind or tree.extra_data.items[se + 2] != 1 or
        start >= tree.extra_data.items.len or tree.extra_data.items[start] != @backingInt(payload.declarator) or
        tree.extra_data.items[de] != @backingInt(w.source_name) or tree.extra_data.items[de + 2] != @backingInt(payload.initializer)) return false;
    if (!@import("import_erasure.zig").equalNode(tree.getNode(w.source_name), binding)) return false;
    const declarator = tree.getNode(payload.declarator);
    if (declarator.tag != payload.declarator_node.tag or !std.meta.eql(declarator.span, payload.declarator_node.span) or
        declarator.data.extra != payload.declarator_node.data.extra) return false;
    const current = tree.getNode(w.source_owner);
    if (current.tag != .empty_statement or !std.meta.eql(current.span, w.source_owner_node.span) or
        live.isSet(@backingInt(w.source_name)) or live.isSet(@backingInt(payload.declarator))) return false;
    var expected = before;
    expected.reference_count = 0;
    expected.write_count = 0;
    if (!@import("source_owned_retirement.zig").equalSymbol(expected, rows[sid])) return false;
    for (ids) |id| if (id == sid) return false;
    for (refs) |ref| if (ref.symbol_id == w.symbol_id) return false;
    for (maps) |map| {
        var it = map.valueIterator();
        while (it.next()) |value| if (value.* == sid) return false;
    }
    for (roots.symbol_ids) |root| if (root == sid) return false;
    return true;
}
