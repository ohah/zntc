//! A real module-local storage SID captures the host identity before Source
//! can expose its mutable import.meta object. Hoisted functions can run before
//! the body prefix, so their first meta evaluation and registry access share
//! the same lazy capture. No source binding is selected by spelling.
const std = @import("std");
const Ast = @import("../../parser/ast.zig");
const NodeIndex = Ast.NodeIndex;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const Reference = @import("../../semantic/symbol.zig").Reference;
const Builder = @import("../runtime_callsite_builder.zig").Builder;
const Token = @import("../../lexer/token.zig").Kind;
pub const Capture = struct { node: NodeIndex, meta: NodeIndex, read: NodeIndex, write: NodeIndex, value: NodeIndex, scope: ScopeId };
pub const Identity = struct {
    module: *const @import("../module.zig").Module,
    owner: @import("../module.zig").SemanticOwnerToken,
    symbol: SymbolId,
    binding: NodeIndex,
    declaration: NodeIndex,
    prefix: NodeIndex,
    scope: ScopeId,
    captures: std.ArrayList(Capture) = .empty,
    sources: std.ArrayList(struct { node: NodeIndex, original: NodeIndex, capture: NodeIndex }) = .empty,
};

fn node(b: *Builder, tag: Ast.Node.Tag, data: Ast.Node.Data) !NodeIndex {
    return b.ast.addNode(.{ .tag = tag, .span = .EMPTY, .data = data });
}

pub fn capture(b: *Builder, scope: ScopeId) !Capture {
    const identity = b.module.legacy_module_identity orelse return error.InvalidLexicalModuleIdentity;
    const read = try b.reference(identity.symbol, scope);
    const value = try b.reference(identity.symbol, scope);
    const name = b.editor.symbols.items[@backingInt(identity.symbol)].name;
    const write = try b.ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    try b.editor.addReference(write, identity.symbol, scope, .{ .write = true }, Reference.NO_STMT, Reference.NO_STMT);
    const zero_span = try b.ast.addString("0");
    const zero = try b.ast.addNode(.{ .tag = .numeric_literal, .span = zero_span, .data = .{ .none = 0 } });
    const undef = try node(b, .unary_expression, .{ .extra = try b.ast.addExtras(&.{ @backingInt(zero), @backingInt(Token.kw_void) }) });
    const check = try node(b, .binary_expression, .{ .binary = .{ .left = read, .right = undef, .flags = @backingInt(Token.eq3) } });
    const span = try b.ast.addString("import.meta");
    const meta = try b.ast.addNode(.{ .tag = .meta_property, .span = span, .data = .{ .none = 2 } });
    const property = try @import("legacy_initialization_registry.zig").literal(b.allocator, b.ast, "url");
    const url = try node(b, .computed_member_expression, .{ .extra = try b.ast.addExtras(&.{ @backingInt(meta), @backingInt(property), 0 }) });
    const assign = try node(b, .assignment_expression, .{ .binary = .{ .left = write, .right = url, .flags = @backingInt(Token.eq) } });
    const result = try node(b, .conditional_expression, .{ .ternary = .{ .a = check, .b = assign, .c = value } });
    const receipt: Capture = .{ .node = result, .meta = meta, .read = read, .write = write, .value = value, .scope = scope };
    try b.module.legacy_module_identity.?.captures.append(b.allocator, receipt);
    return receipt;
}

pub fn ensure(b: *Builder, root: NodeIndex) !void {
    if (b.module.legacy_module_identity != null) return;
    const scope: ScopeId = @fromBackingInt(b.editor.scope_owner_map.get(@backingInt(root)) orelse return error.InvalidLexicalModuleIdentity);
    var traces = try @import("../../transformer/symbol_coverage.zig").collectScopeTraces(b.allocator, b.ast, root, b.editor.symbol_ids.items, b.editor.symbols.items, b.editor.scopes.items, &b.editor.scope_owner_map);
    defer traces.deinit(b.allocator);
    var source_meta: std.ArrayList(struct { index: NodeIndex, scope: ScopeId }) = .empty;
    var iterator = traces.iterator();
    while (iterator.next()) |entry| {
        const idx: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const item = b.ast.getNode(idx);
        if (item.tag != .meta_property or item.data.none != 0 or !std.mem.eql(u8, b.ast.getText(item.span), "import.meta")) continue;
        if (!entry.value_ptr.valid or entry.value_ptr.ambiguous or entry.value_ptr.scope_id == null) return error.InvalidLexicalModuleIdentity;
        try source_meta.append(b.allocator, .{ .index = idx, .scope = @fromBackingInt(entry.value_ptr.scope_id.?) });
    }
    var ordinal: u32 = 0;
    const name = while (true) : (ordinal += 1) {
        const text = try std.fmt.allocPrint(b.allocator, "__moduleURL{d}", .{ordinal});
        if (!b.editor.scope_maps.items[scope.toIndex()].contains(text)) break try b.ast.addString(text);
    };
    const binding = try b.ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const symbol = try b.editor.declare(binding, name, name, scope, .variable_var, Reference.NO_STMT, Reference.NO_STMT);
    const declarator = try node(b, .variable_declarator, .{ .extra = try b.ast.addExtras(&.{ @backingInt(binding), @backingInt(NodeIndex.none), @backingInt(NodeIndex.none) }) });
    const declarations = try b.ast.addNodeList(&.{declarator});
    const declaration = try node(b, .variable_declaration, .{ .extra = try b.ast.addExtras(&.{ 0, declarations.start, declarations.len }) });
    b.module.legacy_module_identity = .{ .module = b.module, .owner = b.module.semantic.?.owner_token, .symbol = symbol, .binding = binding, .declaration = declaration, .prefix = .none, .scope = scope };
    const first = try capture(b, scope);
    b.module.legacy_module_identity.?.prefix = try node(b, .expression_statement, .{ .unary = .{ .operand = first.node, .flags = 0 } });
    try b.declarations.append(b.allocator, declaration);
    for (source_meta.items) |source| {
        const original = try b.ast.addNode(b.ast.getNode(source.index));
        const captured = try capture(b, source.scope);
        const sequence = try node(b, .sequence_expression, .{ .list = try b.ast.addNodeList(&.{ captured.node, original }) });
        b.ast.nodes.items[@backingInt(source.index)] = b.ast.getNode(sequence);
        try b.module.legacy_module_identity.?.sources.append(b.allocator, .{ .node = source.index, .original = original, .capture = captured.node });
    }
}

fn checked(tree: *const Ast.Ast, index: NodeIndex) !Ast.Node {
    if (index.isNone() or @backingInt(index) >= tree.nodes.items.len) return error.InvalidLexicalModuleIdentity;
    return tree.getNode(index);
}

pub fn validate(module: *const @import("../module.zig").Module) !void {
    const identity = module.legacy_module_identity orelse return error.InvalidLexicalModuleIdentity;
    const tree = if (module.ast) |*value| value else return error.InvalidLexicalModuleIdentity;
    const semantic = module.semantic orelse return error.InvalidLexicalModuleIdentity;
    if (identity.module != module or identity.owner == .unassigned or identity.owner != semantic.owner_token or identity.symbol.isNone() or @backingInt(identity.symbol) >= semantic.symbols.items.len) return error.InvalidLexicalModuleIdentity;
    const symbol = semantic.symbols.items[@backingInt(identity.symbol)];
    if (symbol.kind != .variable_var or symbol.scope_id != identity.scope or symbol.origin_scope != identity.scope or identity.binding.isNone() or @backingInt(identity.binding) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(identity.binding)] != @backingInt(identity.symbol)) return error.InvalidLexicalModuleIdentity;
    const root = tree.transformed_root orelse return error.InvalidLexicalModuleIdentity;
    if (semantic.scope_owner_map.get(@backingInt(root)) != @backingInt(identity.scope)) return error.InvalidLexicalModuleIdentity;
    const decl = try checked(tree, identity.declaration);
    if (decl.tag != .variable_declaration or !tree.hasExtra(decl.data.extra, 3) or tree.readExtra(decl.data.extra, 0) != 0 or tree.readExtra(decl.data.extra, 2) != 1) return error.InvalidLexicalModuleIdentity;
    const declarator = try checked(tree, tree.readExtraNode(tree.readExtra(decl.data.extra, 1), 0));
    if (declarator.tag != .variable_declarator or !tree.hasExtra(declarator.data.extra, 3) or tree.readExtraNode(declarator.data.extra, 0) != identity.binding or !tree.readExtraNode(declarator.data.extra, 2).isNone()) return error.InvalidLexicalModuleIdentity;
    var prefix_count: usize = 0;
    var decl_count: usize = 0;
    var it = tree.iterateExtraList((try checked(tree, root)).data.list);
    while (it.next()) |statement| {
        if (statement == identity.prefix) prefix_count += 1;
        if (statement == identity.declaration) decl_count += 1;
    }
    if (prefix_count != 1 or decl_count != 1 or identity.captures.items.len == 0) return error.InvalidLexicalModuleIdentity;
    const prefix = try checked(tree, identity.prefix);
    if (prefix.tag != .expression_statement or prefix.data.unary.operand != identity.captures.items[0].node) return error.InvalidLexicalModuleIdentity;
    for (identity.captures.items) |item| {
        for ([_]NodeIndex{ item.node, item.meta, item.read, item.write, item.value }) |idx| if (idx.isNone() or @backingInt(idx) >= tree.nodes.items.len) return error.InvalidLexicalModuleIdentity;
        const conditional = try checked(tree, item.node);
        if (conditional.tag != .conditional_expression or conditional.data.ternary.c != item.value) return error.InvalidLexicalModuleIdentity;
        const check = try checked(tree, conditional.data.ternary.a);
        const assign = try checked(tree, conditional.data.ternary.b);
        if (check.tag != .binary_expression or check.data.binary.flags != @backingInt(Token.eq3) or check.data.binary.left != item.read or assign.tag != .assignment_expression or assign.data.binary.flags != @backingInt(Token.eq) or assign.data.binary.left != item.write) return error.InvalidLexicalModuleIdentity;
        const void_zero = try checked(tree, check.data.binary.right);
        if (void_zero.tag != .unary_expression or !tree.hasExtra(void_zero.data.extra, 2) or tree.readExtra(void_zero.data.extra, 1) != @backingInt(Token.kw_void)) return error.InvalidLexicalModuleIdentity;
        const zero = try checked(tree, tree.readExtraNode(void_zero.data.extra, 0));
        if (zero.tag != .numeric_literal or !std.mem.eql(u8, tree.getText(zero.span), "0")) return error.InvalidLexicalModuleIdentity;
        const url = try checked(tree, assign.data.binary.right);
        if (url.tag != .computed_member_expression or !tree.hasExtra(url.data.extra, 3) or tree.readExtraNode(url.data.extra, 0) != item.meta) return error.InvalidLexicalModuleIdentity;
        const key = try checked(tree, tree.readExtraNode(url.data.extra, 1));
        const meta = try checked(tree, item.meta);
        if (meta.tag != .meta_property or meta.data.none != 2 or !std.mem.eql(u8, tree.getText(meta.span), "import.meta") or key.tag != .string_literal or !std.mem.eql(u8, tree.getText(key.span), "\"url\"")) return error.InvalidLexicalModuleIdentity;
        for ([_]NodeIndex{ item.read, item.write, item.value }) |ref| {
            if (@backingInt(ref) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(ref)] != @backingInt(identity.symbol)) return error.InvalidLexicalModuleIdentity;
            var count: usize = 0;
            for (semantic.references) |row| if (row.node_index == ref) {
                if (row.symbol_id != identity.symbol or row.scope_id != item.scope or row.flags.declare or row.flags.write != (ref == item.write) or row.flags.read != (ref != item.write)) return error.InvalidLexicalModuleIdentity;
                count += 1;
            };
            if (count != 1) return error.InvalidLexicalModuleIdentity;
        }
    }
    for (identity.sources.items) |source| {
        const expression = try checked(tree, source.node);
        if (expression.tag != .sequence_expression or expression.data.list.len != 2 or tree.readExtraNode(expression.data.list.start, 0) != source.capture or tree.readExtraNode(expression.data.list.start, 1) != source.original) return error.InvalidLexicalModuleIdentity;
        const original = try checked(tree, source.original);
        if (original.tag != .meta_property or original.data.none != 0 or !std.mem.eql(u8, tree.getText(original.span), "import.meta")) return error.InvalidLexicalModuleIdentity;
    }
}

pub fn appendPrefix(b: *Builder, root: NodeIndex, statements: *std.ArrayList(NodeIndex)) !void {
    const prefix = if (b.module.legacy_module_identity) |identity| identity.prefix else .none;
    var it = b.ast.iterateExtraList(b.ast.getNode(root).data.list);
    var present = false;
    while (it.next()) |statement| if (statement == prefix) {
        present = true;
    };
    it = b.ast.iterateExtraList(b.ast.getNode(root).data.list);
    var inserted = present or prefix.isNone();
    while (it.next()) |statement| {
        const item = b.ast.getNode(statement);
        const directive = item.tag == .expression_statement and !item.data.unary.operand.isNone() and b.ast.getNode(item.data.unary.operand).tag == .string_literal;
        if (!inserted and !directive) {
            try statements.append(b.allocator, prefix);
            inserted = true;
        }
        try statements.append(b.allocator, statement);
    }
    if (!inserted) try statements.append(b.allocator, prefix);
}

test "legacy lexical TDZ codegen rejects a forged module meta marker without producer metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(a, "console.log(import.meta.url);");
    var parser = @import("../../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var count: usize = 0;
    for (parser.ast.nodes.items) |*item| if (item.tag == .meta_property) {
        try std.testing.expectEqual(@as(u32, 0), item.data.none);
        item.data.none = 2;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
    var codegen = @import("../../codegen/codegen.zig").Codegen.initWithOptions(a, &parser.ast, .{ .module_format = .esm });
    defer codegen.deinit();
    try std.testing.expectError(error.InvalidModuleRuntimeIdentity, codegen.generate(root));
}
