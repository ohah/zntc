//! Exact producer-owned const capture aliases, never a name-based orphan rule.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const symbol = @import("symbol.zig");
const Scope = @import("scope.zig").Scope;
const ScopeId = @import("scope.zig").ScopeId;
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Reference = symbol.Reference;
fn sameNode(left: Node, right: Node) bool {
    if (left.tag != right.tag or !std.meta.eql(left.span, right.span)) return false;
    return switch (left.tag) {
        .class_declaration, .class_expression, .variable_declaration, .variable_declarator => left.data.extra == right.data.extra,
        else => @import("import_erasure.zig").equalNode(left, right),
    };
}

pub const Witness = struct {
    statement: NodeIndex,
    statement_node: Node,
    declarator: NodeIndex,
    declarator_node: Node,
    initializer: Reference,
    initializer_node: Node,
    read: Reference,
    read_node: Node,
    class_binding_node: Node,
    class_before: symbol.Symbol,
    class_scope: ScopeId,
    replacement: Reference,
};

pub const Source = struct {
    domain: *const Ast,
    source_buffer: []const u8,
    root: NodeIndex,
    symbol_id: symbol.SymbolId,
    before: symbol.Symbol,
    declaration: Reference,
    binding_node: Node,
    owner: NodeIndex,
    owner_node: Node,
    class_binding: NodeIndex,
    class_symbol: symbol.SymbolId,
    parent: ScopeId,
    witness: Witness,
};

const Edges = struct {
    declaration: ?Reference = null,
    read: ?Reference = null,
    declarations: usize = 0,
    reads: usize = 0,
    other: bool = false,
};

fn pureRead(row: Reference) bool {
    return std.meta.eql(row.flags, @as(symbol.ReferenceFlags, .{ .read = true })) and !row.node_index.isNone() and row.declaration_node_index.isNone();
}

fn parentOf(parents: anytype, node: NodeIndex) ?NodeIndex {
    const trace = parents.get(@backingInt(node)) orelse return null;
    if (trace.ambiguous) return null;
    return @fromBackingInt(trace.parent);
}

pub fn captureAll(a: std.mem.Allocator, editor: anytype, root: NodeIndex, completed: anytype) ![]const Source {
    if (completed.count() == 0) return &.{};
    var parents = try @import("../transformer/symbol_coverage.zig").collectParentTraces(a, editor.ast, root);
    defer parents.deinit(a);
    const edges = try a.alloc(Edges, editor.symbols.items.len);
    defer a.free(edges);
    @memset(edges, .{});
    for (editor.references.items) |row| {
        const sid = @backingInt(row.symbol_id);
        if (sid >= edges.len) return error.InvalidSymbol;
        if (row.flags.declare) {
            edges[sid].declarations += 1;
            edges[sid].declaration = row;
        } else if (pureRead(row)) {
            edges[sid].reads += 1;
            edges[sid].read = row;
        } else edges[sid].other = true;
    }
    var result: std.ArrayList(Source) = .empty;
    errdefer result.deinit(a);
    var values = completed.valueIterator();
    while (values.next()) |capture| {
        const raw = capture.symbol_id orelse continue;
        if (raw >= edges.len or capture.binding.isNone() or @backingInt(capture.binding) >= editor.symbol_ids.items.len) return error.InvalidSymbol;
        const before = editor.symbols.items[raw];
        // These other producer roles never reach the native-const alias fold.
        if (before.kind != .variable_const or edges[raw].reads != 1 or edges[raw].other or before.write_count != 0) continue;
        if (before.scope_id.isNone() or before.scope_id.toIndex() >= editor.scopes.items.len or before.origin_scope != before.scope_id or
            before.scope_id != capture.frame.output_scope or before.isExported() or before.reference_count != 1 or
            before.name.start & Ast.STRING_TABLE_BIT == 0 or !std.meta.eql(before.name, capture.name) or
            (before.synthetic_kind != null and before.synthetic_kind != .standalone_generated_binding)) return error.InvalidSymbol;
        const frame = editor.scopes.items[before.scope_id.toIndex()];
        if (frame.blocksMangling()) continue;
        const declaration = edges[raw].declaration orelse return error.ReferenceNotFound;
        const read = edges[raw].read.?;
        if (edges[raw].declarations != 1 or declaration.declaration_node_index != capture.binding or declaration.node_index != .none or
            declaration.scope_id != before.scope_id or !std.meta.eql(declaration.flags, @as(symbol.ReferenceFlags, .{ .declare = true })) or
            editor.symbol_ids.items[@backingInt(capture.binding)] != raw) return error.InvalidSymbol;
        if (read.scope_id.isNone() or read.scope_id.toIndex() >= editor.scopes.items.len) return error.InvalidScope;
        // The alias minifier only moves immutable reads within their actual
        // declaration scope. A field evaluator's nested closure keeps this
        // capture alive; it is not a failed source-retirement proof.
        if (read.scope_id != before.scope_id) continue;
        const binding = editor.ast.getNode(capture.binding);
        if (binding.tag != .binding_identifier or !std.meta.eql(binding.data.string_ref, before.name)) return error.InvalidNode;
        const declarator_index = parentOf(&parents, capture.binding) orelse return error.InvalidNode;
        const statement_index = parentOf(&parents, declarator_index) orelse return error.InvalidNode;
        const declarator = editor.ast.getNode(declarator_index);
        const statement = editor.ast.getNode(statement_index);
        if (declarator.tag != .variable_declarator or statement.tag != .variable_declaration or
            editor.ast.variableDeclarationKind(statement) != .@"const" or !editor.ast.hasExtra(declarator.data.extra, 2) or
            editor.ast.readExtraNode(declarator.data.extra, 0) != capture.binding) return error.InvalidNode;
        const initializer_index = editor.ast.readExtraNode(declarator.data.extra, 2);
        const initializer = (try editor.referenceForNode(initializer_index)) orelse return error.ReferenceNotFound;
        const class_raw = capture.frame.class_symbol_id orelse return error.InvalidSymbol;
        if (class_raw >= editor.symbols.items.len or class_raw == raw or initializer.symbol_id != @as(symbol.SymbolId, @fromBackingInt(class_raw)) or
            !pureRead(initializer) or initializer.scope_id != before.scope_id or editor.symbols.items[class_raw].write_count != 0) return error.InvalidSymbol;
        const read_node = editor.ast.getNode(read.node_index);
        if (read_node.tag != .identifier_reference or !std.meta.eql(read_node.data.string_ref, before.name)) return error.InvalidNode;
        const class_binding = capture.frame.class_binding;
        if (class_binding.isNone() or @backingInt(class_binding) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(class_binding)] != class_raw) return error.InvalidSymbol;
        const owner = parentOf(&parents, class_binding) orelse return error.InvalidNode;
        const owner_node = editor.ast.getNode(owner);
        if ((owner_node.tag != .class_declaration and owner_node.tag != .class_expression) or
            !editor.ast.hasExtra(owner_node.data.extra, ast_mod.ClassExtra.name) or editor.ast.readExtraNode(owner_node.data.extra, ast_mod.ClassExtra.name) != class_binding) return error.InvalidNode;
        const class_scope: ScopeId = @fromBackingInt(editor.scope_owner_map.get(@backingInt(owner)) orelse return error.InvalidScope);
        if (class_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[class_scope.toIndex()].kind != .class_body or editor.scopes.items[class_scope.toIndex()].parent != before.scope_id) return error.InvalidScope;
        try result.append(a, .{
            .domain = editor.ast,
            .source_buffer = editor.ast.source,
            .root = root,
            .symbol_id = @fromBackingInt(raw),
            .before = before,
            .declaration = declaration,
            .binding_node = binding,
            .owner = owner,
            .owner_node = owner_node,
            .class_binding = class_binding,
            .class_symbol = @fromBackingInt(class_raw),
            .parent = frame.parent,
            .witness = .{
                .statement = statement_index,
                .statement_node = statement,
                .declarator = declarator_index,
                .declarator_node = declarator,
                .initializer = initializer,
                .initializer_node = editor.ast.getNode(initializer_index),
                .read = read,
                .read_node = editor.ast.getNode(read.node_index),
                .class_binding_node = editor.ast.getNode(class_binding),
                .class_before = editor.symbols.items[class_raw],
                .class_scope = class_scope,
                .replacement = read,
            },
        });
    }
    return result.toOwnedSlice(a);
}

fn validOwner(source: Source, ast: *const Ast, symbols: []const symbol.Symbol, ids: []const ?u32, scopes: []const Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) bool {
    const raw = @backingInt(source.class_symbol);
    const before = source.before;
    const w = source.witness;
    if (raw >= symbols.len or raw == @backingInt(source.symbol_id) or before.kind != .variable_const or before.reference_count != 1 or before.write_count != 0 or before.isExported() or
        before.name.start & Ast.STRING_TABLE_BIT == 0 or (before.synthetic_kind != null and before.synthetic_kind != .standalone_generated_binding) or
        before.scope_id.isNone() or before.scope_id.toIndex() >= scopes.len or before.origin_scope != before.scope_id or scopes[before.scope_id.toIndex()].blocksMangling() or
        scopes[before.scope_id.toIndex()].parent != source.parent or w.class_before.write_count != 0) return false;
    for ([_]NodeIndex{ source.owner, source.class_binding, source.declaration.declaration_node_index, w.statement, w.declarator, w.initializer.node_index, w.read.node_index }) |node| if (node.isNone() or @backingInt(node) >= ast.nodes.items.len) return false;
    var class_before = w.class_before;
    class_before.reference_count = symbols[raw].reference_count;
    if (!@import("source_owned_retirement.zig").equalSymbol(class_before, symbols[raw])) return false;
    const owner = ast.getNode(source.owner);
    if (!sameNode(owner, source.owner_node) or (owner.tag != .class_declaration and owner.tag != .class_expression) or
        !ast.hasExtra(owner.data.extra, ast_mod.ClassExtra.name) or ast.readExtraNode(owner.data.extra, ast_mod.ClassExtra.name) != source.class_binding or
        @backingInt(source.class_binding) >= ids.len or ids[@backingInt(source.class_binding)] != @as(?u32, @backingInt(source.class_symbol)) or
        !sameNode(ast.getNode(source.class_binding), w.class_binding_node) or !std.meta.eql(before.declaration_span, w.class_binding_node.span) or
        w.class_binding_node.tag != .binding_identifier or !std.meta.eql(w.class_binding_node.data.string_ref, w.class_before.name) or
        owners.get(@backingInt(source.owner)) != @as(?u32, @backingInt(w.class_scope)) or w.class_scope.isNone() or w.class_scope.toIndex() >= scopes.len or
        scopes[w.class_scope.toIndex()].kind != .class_body or scopes[w.class_scope.toIndex()].parent != before.scope_id) return false;
    return source.binding_node.tag == .binding_identifier and std.meta.eql(source.binding_node.data.string_ref, before.name) and
        pureRead(w.read) and w.read.symbol_id == source.symbol_id and w.read.scope_id == before.scope_id and w.read_node.tag == .identifier_reference and std.meta.eql(w.read_node.data.string_ref, before.name) and
        pureRead(w.initializer) and w.initializer.symbol_id == source.class_symbol and w.initializer.scope_id == before.scope_id;
}

pub fn prepare(editor: anytype, source: Source, receipt: @import("function_retirement_receipt.zig").ApplicationReceipt, reachable: *const std.DynamicBitSet) !?Witness {
    if (source.domain != editor.ast or receipt.domain != editor.ast or source.source_buffer.ptr != editor.ast.source.ptr or source.source_buffer.len != editor.ast.source.len) return error.InvalidNode;
    if (!validOwner(source, editor.ast, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, &editor.scope_owner_map)) return error.InvalidSymbol;
    const binding = source.declaration.declaration_node_index;
    if (binding.isNone() or @backingInt(binding) >= reachable.capacity()) return error.InvalidNode;
    if (reachable.isSet(@backingInt(binding))) return null;
    if (!reachable.isSet(@backingInt(source.owner)) or !reachable.isSet(@backingInt(source.class_binding))) return error.InvalidNode;
    const w = source.witness;
    if (@backingInt(w.statement) >= editor.ast.nodes.items.len or editor.ast.getNode(w.statement).tag != .empty_statement or
        !std.meta.eql(editor.ast.getNode(w.statement).span, w.statement_node.span) or reachable.isSet(@backingInt(w.initializer.node_index)) or
        !reachable.isSet(@backingInt(w.read.node_index))) return error.InvalidNode;
    var copies: usize = 0;
    for (receipt.copies) |copy| if (copy.source == w.initializer.node_index or copy.target == w.read.node_index) {
        if (copy.source != w.initializer.node_index or copy.target != w.read.node_index or copy.source_owner != null or !sameNode(copy.source_node, w.initializer_node) or !sameNode(copy.target_node, w.read_node) or
            copy.source_reference == null or !std.meta.eql(copy.source_reference.?, w.initializer) or copy.source_reachable or !copy.target_reachable) return error.InvalidNode;
        copies += 1;
    };
    if (copies != 1) return error.InvalidNode;
    var removed_initializer: usize = 0;
    var changed_read: usize = 0;
    var replacement: ?Reference = null;
    for (receipt.reference_changes) |change| {
        const before = change.before orelse continue;
        if (std.meta.eql(before, w.initializer)) {
            if (change.after != null) return error.InvalidSymbol;
            removed_initializer += 1;
        }
        if (std.meta.eql(before, w.read)) {
            const after = change.after orelse return error.InvalidSymbol;
            if (!pureRead(after) or after.node_index != before.node_index or after.symbol_id != source.class_symbol or after.scope_id != before.scope_id) return error.InvalidSymbol;
            replacement = after;
            changed_read += 1;
        }
    }
    if (removed_initializer != 1 or changed_read != 1 or replacement == null) return error.InvalidSymbol;
    if (!sameNode(editor.ast.getNode(w.read.node_index), w.initializer_node) or
        !sameNode(editor.ast.getNode(w.initializer.node_index), w.initializer_node) or
        @backingInt(w.initializer.node_index) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(w.initializer.node_index)] != null or
        @backingInt(w.read.node_index) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(w.read.node_index)] != @as(?u32, @backingInt(source.class_symbol))) return error.InvalidNode;
    var actual_replacement: usize = 0;
    for (editor.references.items) |row| if (row.node_index == w.read.node_index) {
        if (!std.meta.eql(row, replacement.?)) return error.InvalidSymbol;
        actual_replacement += 1;
    };
    if (actual_replacement != 1) return error.ReferenceNotFound;
    var result = w;
    result.replacement = replacement.?;
    return result;
}

pub fn validateState(retired: anytype, ast: *const Ast, reachable: *const std.DynamicBitSet, symbols: []const symbol.Symbol, ids: []const ?u32, scopes: []const Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), references: []const Reference) bool {
    const w = retired.static_capture_alias orelse return false;
    const sid = @backingInt(retired.symbol_id);
    const before = retired.before;
    const binding = retired.declaration.declaration_node_index;
    const class_raw = @backingInt(retired.source_name_symbol);
    if (class_raw >= symbols.len or class_raw == sid or w.class_before.write_count != 0) return false;
    var expected_class = w.class_before;
    expected_class.reference_count = symbols[class_raw].reference_count;
    if (!@import("source_owned_retirement.zig").equalSymbol(expected_class, symbols[class_raw])) return false;
    if (sid >= symbols.len or before.kind != .variable_const or before.isExported() or before.reference_count != 1 or before.write_count != 0 or
        before.name.start & Ast.STRING_TABLE_BIT == 0 or (before.synthetic_kind != null and before.synthetic_kind != .standalone_generated_binding) or
        before.scope_id.isNone() or before.scope_id.toIndex() >= scopes.len or before.origin_scope != before.scope_id or
        scopes[before.scope_id.toIndex()].blocksMangling() or retired.source_scope != before.scope_id or retired.source_parent != scopes[before.scope_id.toIndex()].parent or
        !retired.closure_scope.isNone() or !retired.closure_parent.isNone() or retired.erased_import != null or binding.isNone() or @backingInt(binding) >= ids.len) return false;
    for ([_]NodeIndex{ retired.source_owner, retired.source_name, binding, w.statement, w.declarator, w.initializer.node_index, w.read.node_index }) |node| {
        if (node.isNone() or @backingInt(node) >= ast.nodes.items.len or @backingInt(node) >= reachable.capacity()) return false;
    }
    const owner = ast.getNode(retired.source_owner);
    if (!sameNode(owner, retired.source_owner_node) or (owner.tag != .class_declaration and owner.tag != .class_expression) or
        !ast.hasExtra(owner.data.extra, ast_mod.ClassExtra.name) or ast.readExtraNode(owner.data.extra, ast_mod.ClassExtra.name) != retired.source_name or
        !reachable.isSet(@backingInt(retired.source_owner)) or !reachable.isSet(@backingInt(retired.source_name)) or
        @backingInt(retired.source_name) >= ids.len or ids[@backingInt(retired.source_name)] != @as(?u32, @backingInt(retired.source_name_symbol)) or
        !sameNode(ast.getNode(retired.source_name), w.class_binding_node) or owners.get(@backingInt(retired.source_owner)) != @as(?u32, @backingInt(w.class_scope)) or
        w.class_scope.isNone() or w.class_scope.toIndex() >= scopes.len or scopes[w.class_scope.toIndex()].kind != .class_body or scopes[w.class_scope.toIndex()].parent != before.scope_id) return false;
    if (retired.declaration_node == null or !sameNode(ast.getNode(binding), retired.declaration_node.?) or
        retired.declaration.symbol_id != retired.symbol_id or retired.declaration.scope_id != before.scope_id or !retired.declaration.node_index.isNone() or
        !std.meta.eql(retired.declaration.flags, @as(symbol.ReferenceFlags, .{ .declare = true })) or reachable.isSet(@backingInt(binding)) or ids[@backingInt(binding)] != null or
        !std.meta.eql(retired.declaration_node.?.data.string_ref, before.name) or !std.meta.eql(before.declaration_span, w.class_binding_node.span) or
        w.read_node.tag != .identifier_reference or !std.meta.eql(w.read_node.data.string_ref, before.name) or
        w.class_binding_node.tag != .binding_identifier or !std.meta.eql(w.class_binding_node.data.string_ref, w.class_before.name) or
        w.statement_node.tag != .variable_declaration or w.declarator_node.tag != .variable_declarator or
        ast.getNode(w.statement).tag != .empty_statement or !std.meta.eql(ast.getNode(w.statement).span, w.statement_node.span) or
        !sameNode(ast.getNode(w.declarator), w.declarator_node) or
        !ast.hasExtra(w.declarator_node.data.extra, 2) or ast.readExtraNode(w.declarator_node.data.extra, 0) != binding or ast.readExtraNode(w.declarator_node.data.extra, 2) != w.initializer.node_index) return false;
    if (!ast.hasExtra(w.statement_node.data.extra, 2) or ast.variableDeclarationKind(w.statement_node) != .@"const") return false;
    const start = ast.extra_data.items[w.statement_node.data.extra + 1];
    if (ast.extra_data.items[w.statement_node.data.extra + 2] != 1 or start >= ast.extra_data.items.len or ast.extra_data.items[start] != @backingInt(w.declarator)) return false;
    if (@backingInt(w.initializer.node_index) >= ids.len or ids[@backingInt(w.initializer.node_index)] != null) return false;
    if (!pureRead(w.initializer) or w.initializer.symbol_id != retired.source_name_symbol or w.initializer.scope_id != before.scope_id or
        !pureRead(w.read) or w.read.symbol_id != retired.symbol_id or w.read.scope_id != before.scope_id or !sameNode(ast.getNode(w.initializer.node_index), w.initializer_node) or
        reachable.isSet(@backingInt(w.initializer.node_index)) or !reachable.isSet(@backingInt(w.read.node_index)) or !sameNode(ast.getNode(w.read.node_index), w.initializer_node) or
        !pureRead(w.replacement) or w.replacement.node_index != w.read.node_index or w.replacement.symbol_id != retired.source_name_symbol or w.replacement.scope_id != before.scope_id or
        @backingInt(w.read.node_index) >= ids.len or ids[@backingInt(w.read.node_index)] != @as(?u32, @backingInt(retired.source_name_symbol))) return false;
    var matches: usize = 0;
    for (references) |row| if (row.node_index == w.replacement.node_index) {
        if (!std.meta.eql(row, w.replacement)) return false;
        matches += 1;
    };
    return matches == 1;
}
