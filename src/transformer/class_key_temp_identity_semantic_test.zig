const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Span = @import("../lexer/token.zig").Span;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_walk = @import("../parser/ast_walk.zig");

fn sameSpan(a: Span, b: Span) bool {
    return a.start == b.start and a.end == b.end;
}

fn checkClassKeyTempIdentity(
    source: []const u8,
    expect_read: bool,
    expect_nested_read_scope: bool,
    legacy_decorator: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var key_span: ?Span = null;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .computed_property_key) continue;
        key_span = node.span;
        break;
    }
    const expected_key_span = key_span orelse return error.MissingComputedClassKey;

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const source_symbol_count = analyzer.symbols.items.len;

    var options: TransformOptions = .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
    };
    options.experimental_decorators = legacy_decorator;
    var transformer = try Transformer.init(allocator, &parser.ast, options);
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;

    const root = try transformer.transform();
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var producer_count: usize = 0;
    var producer_id: ?u32 = null;
    var producer_counter: ?u32 = null;
    var temp_iterator = transformer.temp_symbol_ids_by_counter.iterator();
    while (temp_iterator.next()) |entry| {
        const id = entry.value_ptr.*;
        if (id >= editor.symbols.items.len) return error.InvalidProducerSymbolId;
        if (!sameSpan(editor.symbols.items[id].declaration_span, expected_key_span)) continue;
        producer_count += 1;
        producer_id = id;
        producer_counter = entry.key_ptr.*;
    }
    try std.testing.expectEqual(@as(usize, 1), producer_count);

    const id = producer_id orelse return error.MissingClassKeyProducerSymbol;
    const counter = producer_counter orelse return error.MissingClassKeyProducerSlot;
    const temp_span = transformer.temp_span_by_counter.get(counter) orelse return error.MissingClassKeyTempSpan;
    const symbol = editor.symbols.items[id];
    try std.testing.expect(id >= source_symbol_count);
    try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
    try std.testing.expectEqual(temp_span.start, symbol.name.start);
    try std.testing.expectEqual(temp_span.end, symbol.name.end);
    try std.testing.expect(!symbol.scope_id.isNone());

    var read_count: usize = 0;
    var write_count: usize = 0;
    var nested_read_scope_count: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != id) continue;
        try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
        if (reference.flags.read) {
            read_count += 1;
            if (reference.scope_id != symbol.scope_id) nested_read_scope_count += 1;
        }
        if (reference.flags.write) write_count += 1;
    }
    try std.testing.expect(write_count > 0);
    if (expect_read) try std.testing.expect(read_count > 0);
    if (expect_nested_read_scope) try std.testing.expect(nested_read_scope_count > 0);

    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);
    var binding_count: usize = 0;
    for (reachable) |raw| {
        if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != id) continue;
        if (transformer.ast.nodes.items[raw].tag == .binding_identifier) binding_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);
    for (edited.references) |reference| {
        if (reference.node_index.isNone() or @backingInt(reference.symbol_id) != id) continue;
        try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(reference.node_index)]);
    }
}

test "#4819 class computed-key temps keep producer identity across hostile scopes" {
    // Ten distinct cases exercise class declarations/expressions, nested
    // lexical owners, effectful keys, dynamic lookup, and both class-key
    // prehoist producers.
    try checkClassKeyTempIdentity(
        "function getKey() { return 'x'; } class Box { [getKey()]() {} value = 1; }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "let calls = 0; const keys = { next() { calls++; return 'x'; } }; class Box { [keys.next()]() {} static value = 2; }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "function suffix() { return 'x'; } class Box { ['key' + suffix()]() {} value = 3; }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "const _a = 7; function getKey() { return 'x'; } class Box { [getKey()]() {} value = _a; }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "function make(_a) { const key = 'x'; class Box { [key]() {} value = _a; } return Box; }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "const Box = class { [Symbol.iterator]() {} value = 1; };",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "function make() { eval('_a'); return class { [getKey()]() {} value = 1; }; }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "try { throw 'x'; } catch (error) { class Box { [error]() {} value = 1; } }",
        true,
        true,
        false,
    );
    try checkClassKeyTempIdentity(
        "function getKey() { return 'x'; } function dec() {} class Box { @dec [getKey()]() {} }",
        false,
        false,
        true,
    );
    try checkClassKeyTempIdentity(
        "function getKey() { return 'x'; } function dec() {} class Box { @dec static [getKey()]() {} }",
        false,
        false,
        true,
    );
}
