const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Parser = @import("../parser/parser.zig").Parser;
const ast_mod = @import("../parser/ast.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ES2020 = @import("es2020.zig").ES2020(Transformer);
const helpers = @import("es_helpers.zig");

fn checkExactES2020Temps(source: []const u8, expected_temp_count: usize, lower_default_parameters: bool) !void {
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
        .unsupported = TransformOptions.compat.fromESTarget(if (lower_default_parameters) .es5 else .es2019),
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
        if (node.tag == .function_declaration)
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
    try std.testing.expectEqual(@as(usize, 1), transformer.temp_symbol_ids_by_counter.count());
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
    var producer_counter: ?u32 = null;
    var span_iterator = transformer.temp_span_by_counter.iterator();
    while (span_iterator.next()) |entry| {
        const span = entry.value_ptr.*;
        if (span.start == symbol.name.start and span.end == symbol.name.end) {
            producer_counter = entry.key_ptr.*;
            break;
        }
    }
    const counter = producer_counter orelse return error.MissingTempProducerCounter;
    const recorded_id = transformer.temp_symbol_ids_by_counter.get(counter) orelse
        return error.MissingGeneratorTempProducerIdentity;
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

fn checkES2020DeferredTempProducerHandle(source: []const u8, expression: []const u8, optional_chain: bool) !void {
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

    const expression_start = std.mem.indexOf(u8, source, expression) orelse return error.MissingExpressionSpan;
    const expression_end = expression_start + expression.len;
    var innermost_function: ?ast_mod.NodeIndex = null;
    var innermost_function_width: usize = std.math.maxInt(usize);
    var outermost_function: ?ast_mod.NodeIndex = null;
    var outermost_function_width: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration or node.span.start > expression_start or node.span.end < expression_end) continue;
        const width: usize = node.span.end - node.span.start;
        const function: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        if (width < innermost_function_width) {
            innermost_function = function;
            innermost_function_width = width;
        }
        if (width > outermost_function_width) {
            outermost_function = function;
            outermost_function_width = width;
        }
    }

    const producer_scope: ScopeId = if (innermost_function) |function|
        transformer.originalFunctionScope(function)
    else blk: {
        const program_scope_raw = transformer.scope_owner_map.get(transformer.parser_node_count - 1) orelse
            return error.MissingProgramScope;
        break :blk @fromBackingInt(program_scope_raw);
    };
    transformer.current_scope = producer_scope;
    if (innermost_function) |function| {
        transformer.state_machine_depth = 1;
        if (outermost_function) |outer| {
            if (outer != function) transformer.generator_state_machine_scope = transformer.originalFunctionScope(outer);
        }
    } else {
        // Static field expressions are moved before their final var owner is
        // available. Exercise this real deferred-owner boundary directly.
        transformer.static_field_initializer_depth = 1;
    }

    const expected_start: u32 = @intCast(expression_start);
    const expected_end: u32 = @intCast(expression_end);
    const expression_node = for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.span.start != expected_start or node.span.end != expected_end) continue;
        const node_index: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        if (optional_chain) {
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

    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expect(transformer.pending_temp_producer_refs.items.len >= 2);
    var producer_ids: [32]u64 = undefined;
    var producer_spans: [32]token_mod.Span = undefined;
    var producer_count: usize = 0;
    var reference_nodes: [128]ast_mod.NodeIndex = undefined;
    var reference_producer_ids: [128]u64 = undefined;
    var reference_reads: [128]bool = undefined;
    var reference_writes: [128]bool = undefined;
    var reference_count: usize = 0;
    for (transformer.pending_temp_producer_refs.items) |pending| {
        try std.testing.expectEqual(producer_scope, pending.scope);
        try std.testing.expect(pending.temp_producer_id != 0);
        var allocated_producer_id: ?u64 = null;
        var allocated_span = transformer.temp_span_by_counter.iterator();
        while (allocated_span.next()) |entry| {
            if (entry.value_ptr.start != pending.name_span.start or entry.value_ptr.end != pending.name_span.end) continue;
            allocated_producer_id = transformer.temp_producer_id_by_counter.get(entry.key_ptr.*);
            break;
        }
        try std.testing.expectEqual(allocated_producer_id, pending.temp_producer_id);
        try std.testing.expect(pending.flags.read != pending.flags.write);
        if (producer_count == producer_ids.len or reference_count == reference_nodes.len)
            return error.TooManyDeferredTempReferences;
        var producer_index: ?usize = null;
        for (producer_ids[0..producer_count], 0..) |known_id, index| {
            if (known_id == pending.temp_producer_id) {
                producer_index = index;
                break;
            }
        }
        if (producer_index) |index| {
            try std.testing.expectEqual(producer_spans[index].start, pending.name_span.start);
            try std.testing.expectEqual(producer_spans[index].end, pending.name_span.end);
        } else {
            producer_ids[producer_count] = pending.temp_producer_id;
            producer_spans[producer_count] = pending.name_span;
            producer_count += 1;
        }
        reference_nodes[reference_count] = pending.node;
        reference_producer_ids[reference_count] = pending.temp_producer_id;
        reference_reads[reference_count] = pending.flags.read;
        reference_writes[reference_count] = pending.flags.write;
        reference_count += 1;
    }

    const binding_scope = transformer.nearestVarScope(producer_scope);
    const first_name_span = producer_spans[0];
    const pending_count_before_negative_controls = transformer.pending_temp_producer_refs.items.len;
    const missing_id_binding = try helpers.makeSyntheticBinding(&transformer, first_name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        missing_id_binding,
        first_name_span,
        parser.ast.getNode(expression_node).span,
        binding_scope,
        null,
        null,
    );
    try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(missing_id_binding));
    const wrong_id_binding = try helpers.makeSyntheticBinding(&transformer, first_name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        wrong_id_binding,
        first_name_span,
        parser.ast.getNode(expression_node).span,
        binding_scope,
        null,
        std.math.maxInt(u64),
    );
    try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(wrong_id_binding));
    try std.testing.expectEqual(pending_count_before_negative_controls, transformer.pending_temp_producer_refs.items.len);

    for (producer_ids[0..producer_count], producer_spans[0..producer_count]) |producer_id, name_span| {
        const binding = try helpers.makeSyntheticBinding(&transformer, name_span);
        try transformer.bindHoistedTempWithProducerIdentity(
            binding,
            name_span,
            parser.ast.getNode(expression_node).span,
            binding_scope,
            null,
            producer_id,
        );
        const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingDeferredTempSymbolId;
        const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
        const symbol = editor.symbols.items[symbol_id];
        try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
        var producer_reference_count: usize = 0;
        var producer_reads: usize = 0;
        var producer_writes: usize = 0;
        for (reference_nodes[0..reference_count], reference_producer_ids[0..reference_count], reference_reads[0..reference_count], reference_writes[0..reference_count]) |reference_node, reference_producer_id, reads, writes| {
            if (reference_producer_id != producer_id) continue;
            try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(reference_node));
            var matched = false;
            for (editor.references.items) |reference| {
                if (reference.node_index != reference_node) continue;
                try std.testing.expectEqual(@as(u32, symbol_id), @backingInt(reference.symbol_id));
                try std.testing.expectEqual(reads, reference.flags.read);
                try std.testing.expectEqual(writes, reference.flags.write);
                try std.testing.expect(editor.symbolVisibleFrom(@fromBackingInt(symbol_id), reference.scope_id));
                matched = true;
                break;
            }
            try std.testing.expect(matched);
            producer_reference_count += 1;
            if (reads) producer_reads += 1;
            if (writes) producer_writes += 1;
        }
        try std.testing.expect(producer_reference_count >= 2);
        try std.testing.expect(producer_reads > 0);
        try std.testing.expect(producer_writes > 0);
        try std.testing.expectEqual(@as(u32, @intCast(producer_reference_count)), symbol.reference_count);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const edited = (try transformer.finishSemanticEdit()).?;
    for (reference_nodes[0..reference_count]) |reference_node| {
        const symbol_id = edited.symbol_ids[@backingInt(reference_node)] orelse return error.MissingFinishedTempReferenceId;
        try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(reference_node));
    }
}

fn checkES2020DeferredTempProducerSlotReuse() !void {
    const source = "function first(make) { return make()?.field; } function second(make) { return make()?.field; }";
    const expressions = [_][]const u8{ "make()?.field", "make()?.field" };
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

    var function_scopes: [2]ScopeId = undefined;
    var function_count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        if (function_count == function_scopes.len) break;
        const function: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        function_scopes[function_count] = transformer.originalFunctionScope(function);
        function_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), function_count);

    for (expressions, function_scopes, 0..) |expression, function_scope, index| {
        if (index != 0) {
            // Function-local counters restart at zero; the generated spelling
            // and allocator slot repeat while the producer ID must stay fresh.
            transformer.temp_var_counter = 0;
        }
        transformer.current_scope = function_scope;
        transformer.state_machine_depth = 1;
        transformer.generator_state_machine_scope = .none;
        const expression_start = std.mem.indexOfPos(u8, source, if (index == 0) 0 else std.mem.indexOf(u8, source, expressions[0]).? + expressions[0].len, expression) orelse
            return error.MissingExpressionSpan;
        const expected_start: u32 = @intCast(expression_start);
        const expected_end: u32 = @intCast(expression_start + expression.len);
        const expression_node = for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.span.start != expected_start or node.span.end != expected_end) continue;
            if (ES2020.findOptionalChainBase(&transformer, node) != null)
                break @as(ast_mod.NodeIndex, @fromBackingInt(@intCast(raw)));
        } else return error.MissingOptionalChainExpression;
        const base = ES2020.findOptionalChainBase(&transformer, parser.ast.getNode(expression_node)) orelse
            return error.MissingOptionalChainBase;
        _ = try ES2020.lowerOptionalChain(&transformer, parser.ast.getNode(expression_node), base);
    }

    try std.testing.expectEqual(@as(usize, 4), transformer.pending_temp_producer_refs.items.len);
    const first_id = transformer.pending_temp_producer_refs.items[0].temp_producer_id;
    const first_span = transformer.pending_temp_producer_refs.items[0].name_span;
    const first_scope = transformer.pending_temp_producer_refs.items[0].scope;
    const second = for (transformer.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id != first_id) break pending;
    } else return error.MissingReusedSlotProducer;
    try std.testing.expect(first_id != second.temp_producer_id);
    try std.testing.expectEqualStrings(transformer.ast.getText(first_span), transformer.ast.getText(second.name_span));
    try std.testing.expectEqual(function_scopes[0], first_scope);
    try std.testing.expectEqual(function_scopes[1], second.scope);

    var first_reference_nodes: [16]ast_mod.NodeIndex = undefined;
    var first_reference_count: usize = 0;
    var second_reference_nodes: [16]ast_mod.NodeIndex = undefined;
    var second_reference_count: usize = 0;
    for (transformer.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id == first_id) {
            if (first_reference_count == first_reference_nodes.len) return error.TooManyFirstProducerRefs;
            first_reference_nodes[first_reference_count] = pending.node;
            first_reference_count += 1;
        } else if (pending.temp_producer_id == second.temp_producer_id) {
            if (second_reference_count == second_reference_nodes.len) return error.TooManySecondProducerRefs;
            second_reference_nodes[second_reference_count] = pending.node;
            second_reference_count += 1;
        }
    }
    try std.testing.expect(first_reference_count >= 2);
    try std.testing.expect(second_reference_count >= 2);

    const first_binding = try helpers.makeSyntheticBinding(&transformer, first_span);
    const second_binding = try helpers.makeSyntheticBinding(&transformer, second.name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        first_binding,
        first_span,
        first_span,
        transformer.nearestVarScope(function_scopes[0]),
        null,
        first_id,
    );
    try transformer.bindHoistedTempWithProducerIdentity(
        second_binding,
        second.name_span,
        second.name_span,
        transformer.nearestVarScope(function_scopes[1]),
        null,
        second.temp_producer_id,
    );
    const first_symbol_id = transformer.getSymbolIdAt(first_binding) orelse return error.MissingFirstReusedTempBinding;
    const second_symbol_id = transformer.getSymbolIdAt(second_binding) orelse return error.MissingSecondReusedTempBinding;
    try std.testing.expect(first_symbol_id != second_symbol_id);
    for (first_reference_nodes[0..first_reference_count]) |node|
        try std.testing.expectEqual(@as(?u32, first_symbol_id), transformer.getSymbolIdAt(node));
    for (second_reference_nodes[0..second_reference_count]) |node|
        try std.testing.expectEqual(@as(?u32, second_symbol_id), transformer.getSymbolIdAt(node));
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);
    _ = try transformer.finishSemanticEdit();
}

test "#4819 ES2020 nullish temp carries its producer SymbolId through reads and hoist" {
    try checkExactES2020Temps("function value(make) { return make() ?? 1; }", 1, false);
}

test "#4819 ES2020 optional-chain temp carries its producer SymbolId through reads and hoist" {
    try checkExactES2020Temps("function value(make) { return make()?.field; }", 1, false);
}

test "#4819 ES2020 temp handle keeps nested reference scope under the hoisted owner" {
    try checkExactES2020Temps("function value(make) { if (make()) { return make() ?? 1; } }", 1, false);
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

test "#4819 ES2020 generator temp producer avoids span registry across ten hostile inputs" {
    try checkES2020GeneratorProducerHandle("function* value(make) { yield make()?.field; }", "make()?.field", true, false);
    try checkES2020GeneratorProducerHandle("function* value(make) { yield make() ?? 1; }", "make() ?? 1", false, false);
    try checkES2020GeneratorProducerHandle("function* value(make) { if (make()) { yield make()?.field; } }", "make()?.field", true, true);
    try checkES2020GeneratorProducerHandle("function* value(make) { if (make()) { yield make() ?? 1; } }", "make() ?? 1", false, true);
    try checkES2020GeneratorProducerHandle("function* value(_a, _b, _step, make) { eval(''); yield make()?.field; }", "make()?.field", true, false);
    try checkES2020GeneratorProducerHandle("function* value(make, key) { yield make()?.[key()]; }", "make()?.[key()]", true, false);
    try checkES2020GeneratorProducerHandle("function* value(make) { yield make()?.(); }", "make()?.()", true, false);
    try checkES2020GeneratorProducerHandle("function* value(make, fallback) { yield make().field ?? fallback; }", "make().field ?? fallback", false, false);
    try checkES2020GeneratorProducerHandle("function* value(_a, make) { if (make()) { eval(''); yield make() ?? _a; } }", "make() ?? _a", false, true);
    try checkES2020GeneratorProducerHandle("async function* value(make) { yield await make()?.field; }", "make()?.field", true, false);
}

test "#4819 ES2020 deferred temp producer identity survives ten hostile inputs" {
    try checkES2020DeferredTempProducerHandle("function* value(make) { yield make()?.field; }", "make()?.field", true);
    try checkES2020DeferredTempProducerHandle("function* value(make) { yield make() ?? 1; }", "make() ?? 1", false);
    try checkES2020DeferredTempProducerHandle("function* value(make, key) { yield make()?.[key()]; }", "make()?.[key()]", true);
    try checkES2020DeferredTempProducerHandle("function* value(make) { yield make()?.(); }", "make()?.()", true);
    try checkES2020DeferredTempProducerHandle("function* value(make, fallback) { yield make().field ?? fallback; }", "make().field ?? fallback", false);
    try checkES2020DeferredTempProducerHandle("function* value(_a, make) { eval(''); yield make()?.field; }", "make()?.field", true);
    try checkES2020DeferredTempProducerHandle(
        "function* value(make) { function inner() { return make()?.field; } yield inner(); }",
        "make()?.field",
        true,
    );
    try checkES2020DeferredTempProducerHandle(
        "function* value(make, fallback) { function inner() { return make().field ?? fallback; } yield inner(); }",
        "make().field ?? fallback",
        false,
    );
    try checkES2020DeferredTempProducerHandle("class Box { static value = make()?.field; }", "make()?.field", true);
    try checkES2020DeferredTempProducerHandle("class Box { static value = make().field ?? fallback; }", "make().field ?? fallback", false);
}

test "#4819 ES2020 default-parameter temp keeps the lowered output identity" {
    try checkExactES2020Temps("function value(make, result = make()?.field) { return result; }", 1, true);
}

test "#4819 ES2020 deferred temp keeps distinct producer IDs when the same allocator slot is reused" {
    try checkES2020DeferredTempProducerSlotReuse();
}
