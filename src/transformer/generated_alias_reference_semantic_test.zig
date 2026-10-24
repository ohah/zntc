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
    return expectAliasCaptureWithText(base, alias, body, prefix, true);
}

fn expectAliasCaptureWithText(base: []const u8, alias: []const u8, body: []const u8, prefix: []const u8, ref_has_alias: bool) !void {
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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    // Existing codegen supports selected output names keyed by SymbolId,
    // without requiring every copied AST reference's text to be rewritten.
    transformer.block_rename_map = .empty;
    try transformer.block_rename_map.?.put(allocator, outer_id, alias);
    transformer.unresolved_references = &analyzer.unresolved_references;
    var refs: usize = 0;
    var writes: usize = 0;
    for (analyzer.references.items) |reference| {
        if (reference.flags.declare or @backingInt(reference.symbol_id) != parameter_id) continue;
        if (ref_has_alias) transformer.ast.nodes.items[@backingInt(reference.node_index)].data.string_ref = alias_span;
        try transformer.rebindOutputReference(reference.node_index, outer_id);
        const current = (try transformer.semantic_editor.?.referenceForNode(reference.node_index)).?;
        try std.testing.expectEqual(outer_id, @backingInt(current.symbol_id));
        try std.testing.expectEqual(reference.scope_id, current.scope_id);
        refs += 1;
        if (reference.flags.write) writes += 1;
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
    try std.testing.expectEqual(refs, transformer.semantic_editor.?.symbols.items[outer_id].reference_count);
    try std.testing.expectEqual(writes, transformer.semantic_editor.?.symbols.items[outer_id].write_count);
    try std.testing.expectEqual(@as(u32, 0), transformer.semantic_editor.?.symbols.items[parameter_id].reference_count);
    try std.testing.expectEqual(@as(u32, 0), transformer.semantic_editor.?.symbols.items[parameter_id].write_count);
    // Exercise the final SymbolId consumer with distinct chosen output names.
    // AST text alone would still look correct after a corrupt semantic rebind.
    var overrides: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    const selected = if (ref_has_alias) "outer_slot" else transformer.block_rename_map.?.get(outer_id).?;
    try overrides.put(allocator, outer_id, selected);
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
    try std.testing.expectEqual(refs + 1, std.mem.count(u8, code, selected));
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

test "deferred alias spelling retains exact producer reference read" {
    try expectAliasCaptureWithText("value", "value$1", "return value;", "", false);
}
test "deferred alias spelling retains repeated producer references" {
    try expectAliasCaptureWithText("item", "item$9", "return item+item;", "", false);
}
test "deferred alias spelling retains producer update" {
    try expectAliasCaptureWithText("count", "count$12", "return ++count;", "", false);
}
test "deferred alias spelling retains producer assignment" {
    try expectAliasCaptureWithText("_value", "_value$2", "return _value=2;", "", false);
}
test "deferred alias spelling retains literal dollar base" {
    try expectAliasCaptureWithText("v$0", "v$0$3", "return v$0??7;", "", false);
}
test "deferred alias spelling retains optional receiver" {
    try expectAliasCaptureWithText("value", "value$1", "return value?.field;", "", false);
}
test "deferred alias spelling retains nested scope reference" {
    try expectAliasCaptureWithText("value", "value$1", "return (()=>value)();", "", false);
}
test "deferred alias spelling retains compound target" {
    try expectAliasCaptureWithText("value", "value$1", "return value+=2;", "", false);
}
test "deferred alias spelling preserves another dollar binding" {
    try expectAliasCaptureWithText("value", "value$2", "return [value,value$1];", "var value$1=99;", false);
}
test "deferred alias spelling retains catch scope reference" {
    try expectAliasCaptureWithText("value", "value$1", "try{throw 0}catch(other){return value}", "", false);
}

test "deferred alias spelling exposes an invisible producer identity instead of repairing it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function hidden(){let value=1;return value;}function visible(value){return value;}";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var hidden: ?u32 = null;
    var parameter: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        if (symbol.kind == .variable_let) hidden = @intCast(index);
        if (symbol.kind == .parameter) parameter = @intCast(index);
    }
    const hidden_id = hidden.?;
    const parameter_id = parameter.?;
    var target: ?@import("../semantic/symbol.zig").Reference = null;
    for (analyzer.references.items) |reference| {
        if (!reference.flags.declare and @backingInt(reference.symbol_id) == parameter_id) target = reference;
    }
    const reference = target.?;
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.unresolved_references = &analyzer.unresolved_references;
    // The public editing API rejects invisible pairs. Initialize with a valid
    // pair, then deliberately poison both tables to model a broken producer.
    try transformer.rebindOutputReference(reference.node_index, parameter_id);
    const editor = &transformer.semantic_editor.?;
    for (editor.references.items) |*row| {
        if (row.node_index == reference.node_index) row.symbol_id = @fromBackingInt(hidden_id);
    }
    const raw = @backingInt(reference.node_index);
    editor.symbol_ids.items[raw] = hidden_id;
    transformer.symbol_ids.items[raw] = hidden_id;
    editor.symbols.items[hidden_id].reference_count += 1;
    editor.symbols.items[parameter_id].reference_count -= 1;
    try std.testing.expect(!editor.symbolVisibleFrom(@fromBackingInt(hidden_id), reference.scope_id));
    try semantic_edit.bindOutputScopesAndReferences(&transformer, root, @fromBackingInt(0));
    try std.testing.expectEqual(hidden_id, transformer.getSymbolIdAt(reference.node_index).?);
    try std.testing.expect(!editor.symbolVisibleFrom(@fromBackingInt(hidden_id), reference.scope_id));
    var empty: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const report = try @import("symbol_coverage.zig").checkExact(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        transformer.symbol_ids.items,
        editor.symbols.items,
        editor.scopes.items,
        editor.scope_maps.items,
        &editor.scope_owner_map,
        editor.references.items,
        &.{},
        &editor.helper_scope_map,
        &empty,
        &empty,
        &transformer.reference_origin_map,
    );
    try std.testing.expect(report.invisible_reference > 0);
    try std.testing.expect(!report.isClean());
}
