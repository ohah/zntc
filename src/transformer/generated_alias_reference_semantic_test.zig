const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const semantic_edit = @import("transformer/semantic_edit.zig");

// Exercise the handoff used when a lowerer emits a fresh spelling while
// explicitly selecting an existing outer binding. The inner parameter still
// has the base name, but cannot capture a reference spelled with the alias.
fn expectAliasCapture(base: []const u8, alias: []const u8, body: []const u8, prefix: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try std.fmt.allocPrint(allocator, "{s}function outer(){{let {s}=1;return function({s}){{{s}}};}}", .{ prefix, base, base, body });
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    var outer: ?u32 = null;
    var parameter: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (!std.mem.eql(u8, symbol.nameText(source), base)) continue;
        if (symbol.kind == .variable_let) outer = @intCast(raw);
        if (symbol.kind == .parameter) parameter = @intCast(raw);
    }
    const outer_id = outer orelse return error.MissingOuterAliasProducer;
    const parameter_id = parameter orelse return error.MissingBaseNameShadow;
    var binding: @import("../parser/ast.zig").NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .binding_identifier and analyzer.symbol_ids.items[raw] == outer_id)
            binding = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!binding.isNone());
    const alias_span = try parser.ast.addString(alias);
    parser.ast.nodes.items[@backingInt(binding)].data.string_ref = alias_span;
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.unresolved_references = &analyzer.unresolved_references;
    var refs: usize = 0;
    for (analyzer.references.items) |reference| {
        if (reference.flags.declare or @backingInt(reference.symbol_id) != parameter_id) continue;
        transformer.ast.nodes.items[@backingInt(reference.node_index)].data.string_ref = alias_span;
        try transformer.rebindOutputReference(reference.node_index, outer_id);
        const current = (try transformer.semantic_editor.?.referenceForNode(reference.node_index)).?;
        try std.testing.expectEqual(outer_id, @backingInt(current.symbol_id));
        try std.testing.expectEqual(reference.scope_id, current.scope_id);
        refs += 1;
    }
    try std.testing.expect(refs > 0);
    const symbol_count = transformer.semantic_editor.?.symbols.items.len;
    const scope_count = transformer.semantic_editor.?.scopes.items.len;
    try semantic_edit.bindOutputScopesAndReferences(&transformer, root, @fromBackingInt(0));
    try std.testing.expectEqual(symbol_count, transformer.semantic_editor.?.symbols.items.len);
    try std.testing.expectEqual(scope_count, transformer.semantic_editor.?.scopes.items.len);
    for (analyzer.references.items) |reference| {
        if (reference.flags.declare or @backingInt(reference.symbol_id) != parameter_id) continue;
        const current = (try transformer.semantic_editor.?.referenceForNode(reference.node_index)).?;
        try std.testing.expectEqual(outer_id, transformer.getSymbolIdAt(reference.node_index).?);
        try std.testing.expectEqual(outer_id, @backingInt(current.symbol_id));
        try std.testing.expectEqual(reference.scope_id, current.scope_id);
        try std.testing.expectEqual(reference.flags, current.flags);
    }
    // Exercise the final SymbolId consumer with distinct chosen output names.
    // AST text alone would still look correct after a corrupt semantic rebind.
    var overrides: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    try overrides.put(allocator, outer_id, "outer_slot");
    try overrides.put(allocator, parameter_id, "inner_slot");
    const editor = &transformer.semantic_editor.?;
    var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(allocator, transformer.ast, .{
        .semantic_symbol_ids = transformer.symbol_ids.items,
        .semantic_symbols = editor.symbols.items,
        .semantic_symbol_name_overrides = &overrides,
        .semantic_scope_maps = editor.scope_maps.items,
        .generated_iife_scope_owner_map = &editor.scope_owner_map,
    });
    const code = try codegen.generate(root);
    try std.testing.expectEqual(refs + 1, std.mem.count(u8, code, "outer_slot"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "inner_slot"));
}

test "exact generated alias survives base-name parameter shadow read" {
    try expectAliasCapture("value", "value$1", "return value;", "");
}
test "exact generated alias survives repeated base-name reads" {
    try expectAliasCapture("item", "item$9", "return item+item;", "");
}
test "exact generated alias survives base-name update" {
    try expectAliasCapture("count", "count$12", "return ++count;", "");
}
test "exact generated alias survives base-name assignment" {
    try expectAliasCapture("_value", "_value$2", "return _value=2;", "");
}
test "exact generated alias preserves literal dollar base" {
    try expectAliasCapture("v$0", "v$0$3", "return v$0??7;", "");
}
test "exact generated alias survives optional receiver shadow" {
    try expectAliasCapture("value", "value$1", "return value?.field;", "");
}
test "exact generated alias survives nested lexical scope" {
    try expectAliasCapture("value", "value$1", "return (()=>value)();", "");
}
test "exact generated alias survives compound target shadow" {
    try expectAliasCapture("value", "value$1", "return value+=2;", "");
}
test "exact generated alias preserves another literal dollar binding" {
    try expectAliasCapture("value", "value$2", "return [value,value$1];", "var value$1=99;");
}
test "exact generated alias survives catch scope ancestry" {
    try expectAliasCapture("value", "value$1", "try{throw 0}catch(other){return value}", "");
}
