const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const ast_mod = @import("../parser/ast.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

fn checkExactES2020Temps(source: []const u8, expected_temp_count: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const source_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2019),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, expected_temp_count), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var temp_ids = std.AutoHashMapUnmanaged(u32, void).empty;
    defer temp_ids.deinit(allocator);
    for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, raw_id| {
        if (symbol.synthetic_kind != .standalone_temp_binding) continue;
        try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
        const id: u32 = @intCast(raw_id);
        try temp_ids.put(allocator, id, {});

        var reference_count: usize = 0;
        var reads: usize = 0;
        var writes: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.node_index.isNone()) continue;
            try std.testing.expect(editor.symbolVisibleFrom(@fromBackingInt(id), reference.scope_id));
            try std.testing.expect(reference.flags.read != reference.flags.write);
            if (reference.flags.read) reads += 1;
            if (reference.flags.write) writes += 1;
            reference_count += 1;
        }
        try std.testing.expect(reference_count >= 2);
        try std.testing.expect(reads > 0);
        try std.testing.expect(writes > 0);
        try std.testing.expectEqual(@as(u32, @intCast(reference_count)), symbol.reference_count);
    }
    try std.testing.expectEqual(expected_temp_count, temp_ids.count());

    const edited = (try transformer.finishSemanticEdit()).?;
    var binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw]) |id| {
            if (temp_ids.contains(id)) binding_count += 1;
        }
    }
    try std.testing.expectEqual(expected_temp_count, binding_count);
    for (edited.references) |reference| {
        if (reference.node_index.isNone() or !temp_ids.contains(@backingInt(reference.symbol_id))) continue;
        try std.testing.expectEqual(
            @as(?u32, @backingInt(reference.symbol_id)),
            edited.symbol_ids[@backingInt(reference.node_index)],
        );
    }
}

test "#4819 ES2020 nullish temp carries its producer SymbolId through reads and hoist" {
    try checkExactES2020Temps("function value(make) { return make() ?? 1; }", 1);
}

test "#4819 ES2020 optional-chain temp carries its producer SymbolId through reads and hoist" {
    try checkExactES2020Temps("function value(make) { return make()?.field; }", 1);
}

test "#4819 ES2020 temp handle keeps nested reference scope under the hoisted owner" {
    try checkExactES2020Temps("function value(make) { if (make()) { return make() ?? 1; } }", 1);
}
