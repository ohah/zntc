const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Parser = @import("../parser/parser.zig").Parser;
const ast_mod = @import("../parser/ast.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ES2020 = @import("es2020.zig").ES2020(Transformer);

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

fn checkExactES2020GeneratorTemp(source: []const u8, expression: []const u8, expect_nested_reference_scope: bool) !void {
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
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    _ = std.mem.indexOf(u8, source, expression) orelse return error.MissingExpressionSpan;
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
            if (expect_nested_reference_scope)
                try std.testing.expect(reference.scope_id != symbol.scope_id);
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
    try std.testing.expectEqual(@as(usize, 1), temp_ids.count());

    const edited = (try transformer.finishSemanticEdit()).?;
    var binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw]) |id| {
            if (temp_ids.contains(id)) binding_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);
    for (edited.references) |reference| {
        if (reference.node_index.isNone() or !temp_ids.contains(@backingInt(reference.symbol_id))) continue;
        try std.testing.expectEqual(
            @as(?u32, @backingInt(reference.symbol_id)),
            edited.symbol_ids[@backingInt(reference.node_index)],
        );
    }
}

fn checkES2020GeneratorProducerHandle(
    source: []const u8,
    expression: []const u8,
    optional_chain: bool,
    use_nested_scope: bool,
) !void {
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

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
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

    const function_owner = for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration and node.span.start == 0)
            break @as(ast_mod.NodeIndex, @fromBackingInt(@intCast(raw)));
    } else return error.MissingGeneratorFunction;
    const function_scope = transformer.originalFunctionScope(function_owner);
    const producer_scope = if (use_nested_scope) blk: {
        for (analyzer.scopes.items, 0..) |scope, raw_scope| {
            if (scope.parent == function_scope and scope.kind == .block)
                break :blk @as(@import("../semantic/scope.zig").ScopeId, @fromBackingInt(@intCast(raw_scope)));
        }
        return error.MissingNestedGeneratorBlockScope;
    } else function_scope;
    transformer.current_scope = producer_scope;
    transformer.state_machine_depth = 1;
    transformer.generator_state_machine_scope = function_scope;

    const expression_start = std.mem.indexOf(u8, source, expression) orelse return error.MissingExpressionSpan;
    const expected_start: u32 = @intCast(expression_start);
    const expected_end: u32 = @intCast(expression_start + expression.len);
    const expression_node = for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.span.start != expected_start) continue;
        const node_index: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        if (optional_chain) {
            if (node.span.end != expected_end) continue;
            if (ES2020.findOptionalChainBase(&transformer, node) != null) break node_index;
        } else if (node.tag == .logical_expression and
            node.data.binary.flags == @backingInt(token_mod.Kind.question2))
        {
            break node_index;
        }
    } else return error.MissingExpressionNode;

    if (optional_chain) {
        const base = ES2020.findOptionalChainBase(&transformer, parser.ast.getNode(expression_node)) orelse
            return error.MissingOptionalChainBase;
        _ = try ES2020.lowerOptionalChain(&transformer, parser.ast.getNode(expression_node), base);
    } else {
        _ = try ES2020.lowerNullishCoalescing(&transformer, parser.ast.getNode(expression_node));
    }

    try std.testing.expectEqual(@as(usize, 1), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_state_temp_symbols.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var temp_iterator = transformer.synthetic_temp_symbol_ids.iterator();
    const temp_entry = temp_iterator.next() orelse return error.MissingReservedTemp;
    const raw_id = temp_entry.value_ptr.*;
    const symbol_id: u32 = raw_id;
    const symbol = editor.symbols.items[symbol_id];
    try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
    try std.testing.expectEqual(function_scope, symbol.origin_scope);
    try std.testing.expectEqual(@as(?@TypeOf(symbol.synthetic_kind.?), null), symbol.synthetic_kind);
    const recorded_id = transformer.generator_state_temp_symbols.get(symbol.name.start) orelse
        return error.MissingGeneratorTempIdentity;
    try std.testing.expectEqual(@as(u32, @intCast(symbol_id)), recorded_id);

    var reference_count: usize = 0;
    var reads: usize = 0;
    var writes: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != symbol_id or reference.node_index.isNone()) continue;
        try std.testing.expectEqual(producer_scope, reference.scope_id);
        try std.testing.expect(reference.flags.read != reference.flags.write);
        if (reference.flags.read) reads += 1;
        if (reference.flags.write) writes += 1;
        reference_count += 1;
        try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(reference.node_index));
    }
    try std.testing.expect(reference_count >= 2);
    try std.testing.expect(reads > 0);
    try std.testing.expect(writes > 0);
    try std.testing.expectEqual(@as(u32, @intCast(reference_count)), symbol.reference_count);

    var binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= transformer.symbol_ids.items.len) continue;
        if (transformer.symbol_ids.items[raw]) |id| {
            if (id == symbol_id) binding_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), binding_count);
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

test "#4819 ES2020 optional-chain temp reserves its SymbolId before generator callback hoisting" {
    try checkExactES2020GeneratorTemp("function* value(make) { yield make()?.field; }", "make()?.field", false);
}

test "#4819 ES2020 nullish temp reserves its SymbolId before generator callback hoisting" {
    try checkExactES2020GeneratorTemp("function* value(make) { yield make() ?? 1; }", "make() ?? 1", false);
}

test "#4819 ES2020 generator temp keeps nested block reference scopes under the wrapper owner" {
    try checkExactES2020GeneratorTemp(
        "function* value(make) { if (make()) { yield make()?.field; } }",
        "make()?.field",
        true,
    );
}

test "#4819 ES2020 optional-chain producer owns its temp before generator callback hoisting" {
    try checkES2020GeneratorProducerHandle("function* value(make) { yield make()?.field; }", "make()?.field", true, false);
}

test "#4819 ES2020 nullish producer owns its temp before generator callback hoisting" {
    try checkES2020GeneratorProducerHandle("function* value(make) { yield make() ?? 1; }", "make() ?? 1", false, false);
}

test "#4819 ES2020 generator temp producer preserves nested reference ScopeId" {
    try checkES2020GeneratorProducerHandle(
        "function* value(make) { if (make()) { yield make()?.field; } }",
        "make()?.field",
        true,
        true,
    );
}
