const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Ast = @import("../parser/ast.zig").Ast;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const MethodExtra = @import("../parser/ast.zig").MethodExtra;
const ast_walk = @import("../parser/ast_walk.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

test "#4819 ES5 class methods retain original scope on emitted functions and bind body temps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Box {
        \\  stamp = 0;
        \\  constructor(v) { this.value = v.next() ?? 1; }
        \\  ["read"](x) { return x.next() ?? this.value; }
        \\  get current() { return this.read() ?? 0; }
        \\  set current(v) { this.value = v.next() ?? 2; }
        \\}
        \\const Direct = class Named { constructor(v) { this.value = v.next() ?? 3; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var original_methods: std.ArrayList(struct { owner: NodeIndex, scope: u32 }) = .empty;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const owner: NodeIndex = @enumFromInt(@as(u32, @intCast(index)));
        if (analyzer.scope_owner_map.get(@intFromEnum(owner))) |scope| {
            try original_methods.append(allocator, .{ .owner = owner, .scope = scope });
        }
    }
    try std.testing.expectEqual(@as(usize, 5), original_methods.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_temp_refs: usize = 0;
    for (original_methods.items) |method| {
        try std.testing.expect(edited.scope_owner_map.get(@intFromEnum(method.owner)) == null);
        var final_owner: ?NodeIndex = null;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != method.scope) continue;
            try std.testing.expect(final_owner == null);
            final_owner = @enumFromInt(entry.key_ptr.*);
        }
        const owner = final_owner orelse return error.TestUnexpectedResult;
        const tag = transformer.ast.getNode(owner).tag;
        try std.testing.expect(tag == .function_declaration or tag == .function_expression);
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @intFromEnum(owner)) != null);
    }
    for (edited.references) |ref| {
        if (ref.node_index.isNone() or @intFromEnum(ref.node_index) < transformer.parser_node_count) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.startsWith(u8, name, "_")) continue;
        for (original_methods.items) |method| {
            if (@intFromEnum(ref.scope_id) == method.scope) generated_temp_refs += 1;
        }
    }
    try std.testing.expect(generated_temp_refs >= 5);
}

test "#4819 decorated explicit constructor binds generated nullish temp in original scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box {
        \\  @logged field = 1;
        \\  constructor(value) { this.field = value.next() ?? 2; }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const key_idx: NodeIndex = @enumFromInt(parser.ast.extra_data.items[node.data.extra + MethodExtra.key]);
        const key = parser.ast.getNode(key_idx);
        if (key.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(key.data.string_ref), "constructor")) continue;
        ctor_scope = analyzer.scope_owner_map.get(@as(u32, @intCast(index)));
    }
    const source_scope = ctor_scope orelse return error.TestUnexpectedResult;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;

    var ctor_owners: usize = 0;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != source_scope) continue;
        const owner: NodeIndex = @enumFromInt(entry.key_ptr.*);
        try std.testing.expect(transformer.ast.getNode(owner).tag == .function_declaration);
        ctor_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ctor_owners);

    var ctor_temp_refs: usize = 0;
    for (edited.references) |ref| {
        if (@intFromEnum(ref.scope_id) != source_scope or ref.node_index.isNone()) continue;
        if (@intFromEnum(ref.node_index) < transformer.parser_node_count) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.startsWith(u8, name, "_")) continue;
        try std.testing.expectEqual(source_scope, @intFromEnum(edited.symbols.items[@intFromEnum(ref.symbol_id)].scope_id));
        ctor_temp_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ctor_temp_refs);
}
