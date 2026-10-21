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
const ES2021 = @import("es2021.zig").ES2021(Transformer);
const ES2015Spread = @import("es2015_spread.zig").ES2015Spread(Transformer);
const helpers = @import("es_helpers.zig");

const Lowering = enum {
    nullish_assignment,
    spread_call,
    spread_new,
};

fn isFunctionTag(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .function_declaration, .function_expression, .function, .method_definition, .arrow_function_expression => true,
        else => false,
    };
}

fn findExpressionNode(
    transformer: *Transformer,
    source: []const u8,
    expression: []const u8,
    lowering: Lowering,
    occurrence: usize,
) !ast_mod.NodeIndex {
    var search_start: usize = 0;
    for (0..occurrence) |_| {
        const previous = std.mem.indexOfPos(u8, source, search_start, expression) orelse return error.MissingExpressionSpan;
        search_start = previous + expression.len;
    }
    const start = std.mem.indexOfPos(u8, source, search_start, expression) orelse return error.MissingExpressionSpan;
    const expected_start: u32 = @intCast(start);
    const expected_end: u32 = @intCast(start + expression.len);
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.span.start != expected_start or node.span.end != expected_end) continue;
        const matches = switch (lowering) {
            .nullish_assignment => node.tag == .assignment_expression and
                node.data.binary.flags == @backingInt(token_mod.Kind.question2_eq),
            .spread_call => node.tag == .call_expression,
            .spread_new => node.tag == .new_expression,
        };
        if (matches) return @fromBackingInt(@intCast(raw));
    }
    return error.MissingLoweringExpression;
}

fn expressionScope(
    transformer: *Transformer,
    root: ast_mod.NodeIndex,
    expression_span: token_mod.Span,
) ScopeId {
    var best_scope = transformer.scope_owner_map.get(@backingInt(root)) orelse return .none;
    var best_width: u32 = std.math.maxInt(u32);
    var owners = transformer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.key_ptr.* >= transformer.ast.nodes.items.len) continue;
        const owner: ast_mod.NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const node = transformer.ast.getNode(owner);
        if (node.span.start > expression_span.start or node.span.end < expression_span.end) continue;
        const width = node.span.end - node.span.start;
        if (width >= best_width) continue;
        best_scope = entry.value_ptr.*;
        best_width = width;
    }
    return @fromBackingInt(best_scope);
}

fn expectPendingProducerIdMatchesAllocator(
    transformer: *Transformer,
    pending: anytype,
) !void {
    var allocator_id: ?u64 = null;
    var spans = transformer.temp_span_by_counter.iterator();
    while (spans.next()) |entry| {
        if (entry.value_ptr.start != pending.name_span.start or entry.value_ptr.end != pending.name_span.end) continue;
        allocator_id = transformer.temp_producer_id_by_counter.get(entry.key_ptr.*);
        break;
    }
    try std.testing.expectEqual(allocator_id, pending.temp_producer_id);
}

fn checkDeferredManualCapture(
    source: []const u8,
    expression: []const u8,
    lowering: Lowering,
    static_initializer: bool,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    var transformer_value = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer_value.initSymbolIds(analyzer.symbol_ids.items);
    transformer_value.symbols = analyzer.symbols.items;
    transformer_value.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer_value.references = analyzer.references.items;
    transformer_value.scopes = analyzer.scopes.items;
    transformer_value.scope_maps = analyzer.scope_maps.items;
    transformer_value.scope_owner_map = analyzer.scope_owner_map;
    transformer_value.unresolved_references = &analyzer.unresolved_references;
    transformer_value.semantic_edit_enabled = true;
    var transformer = &transformer_value;

    const expression_node = try findExpressionNode(transformer, source, expression, lowering, 0);
    const expression_span = transformer.ast.getNode(expression_node).span;
    const reference_scope = expressionScope(transformer, root, expression_span);
    try std.testing.expect(!reference_scope.isNone());
    transformer.current_scope = reference_scope;
    if (static_initializer) {
        transformer.static_field_initializer_depth = 1;
    } else {
        // The real source functions in these fixtures are generators. Keep the
        // callback output owner unresolved while invoking the exact lowering.
        transformer.state_machine_depth = 1;
        transformer.generator_state_machine_scope = .none;
    }

    switch (lowering) {
        .nullish_assignment => _ = try ES2021.lowerNullishAssignment(transformer, transformer.ast.getNode(expression_node)),
        .spread_call => {
            try std.testing.expect(ES2015Spread.hasSpreadArg(transformer, transformer.ast.getNode(expression_node)));
            _ = try ES2015Spread.lowerSpreadCall(transformer, transformer.ast.getNode(expression_node));
        },
        .spread_new => _ = try ES2015Spread.lowerSpreadNew(transformer, transformer.ast.getNode(expression_node)),
    }

    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(@as(usize, 2), transformer.pending_temp_producer_refs.items.len);
    const producer_id = transformer.pending_temp_producer_refs.items[0].temp_producer_id;
    const name_span = transformer.pending_temp_producer_refs.items[0].name_span;
    var reference_nodes: [2]ast_mod.NodeIndex = undefined;
    var reference_scopes: [2]ScopeId = undefined;
    var reference_flags: [2]@import("../semantic/symbol.zig").ReferenceFlags = undefined;
    try std.testing.expect(producer_id != 0);
    var saw_read = false;
    var saw_write = false;
    for (transformer.pending_temp_producer_refs.items, 0..) |pending, index| {
        reference_nodes[index] = pending.node;
        reference_scopes[index] = pending.scope;
        reference_flags[index] = pending.flags;
        try std.testing.expectEqual(producer_id, pending.temp_producer_id);
        try std.testing.expectEqual(reference_scope, pending.scope);
        try std.testing.expectEqual(name_span.start, pending.name_span.start);
        try std.testing.expectEqual(name_span.end, pending.name_span.end);
        try std.testing.expect(pending.flags.read != pending.flags.write);
        try expectPendingProducerIdMatchesAllocator(transformer, pending);
        saw_read = saw_read or pending.flags.read;
        saw_write = saw_write or pending.flags.write;
    }
    try std.testing.expect(saw_read and saw_write);

    const binding_scope = transformer.nearestVarScope(reference_scope);
    const pending_count = transformer.pending_temp_producer_refs.items.len;
    const missing_binding = try helpers.makeSyntheticBinding(transformer, name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        missing_binding,
        name_span,
        expression_span,
        binding_scope,
        null,
        null,
    );
    try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(missing_binding));
    const wrong_binding = try helpers.makeSyntheticBinding(transformer, name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        wrong_binding,
        name_span,
        expression_span,
        binding_scope,
        null,
        std.math.maxInt(u64),
    );
    try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(wrong_binding));
    try std.testing.expectEqual(pending_count, transformer.pending_temp_producer_refs.items.len);

    const binding = try helpers.makeSyntheticBinding(transformer, name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        binding,
        name_span,
        expression_span,
        binding_scope,
        null,
        producer_id,
    );
    const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingCapturedTempBinding;
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const symbol = editor.symbols.items[symbol_id];
    try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
    try std.testing.expectEqual(binding_scope, symbol.scope_id);
    try std.testing.expectEqual(@as(u32, 2), symbol.reference_count);

    for (reference_nodes, reference_scopes, reference_flags) |node, scope, flags| {
        var matched = false;
        for (editor.references.items) |reference| {
            if (reference.node_index != node) continue;
            try std.testing.expectEqual(@as(u32, symbol_id), @backingInt(reference.symbol_id));
            try std.testing.expectEqual(scope, reference.scope_id);
            try std.testing.expect(std.meta.eql(flags, reference.flags));
            try std.testing.expect(editor.symbolVisibleFrom(@fromBackingInt(symbol_id), reference.scope_id));
            matched = true;
            break;
        }
        try std.testing.expect(matched);
    }

    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const edited = (try transformer.finishSemanticEdit()).?;
    for (reference_nodes) |node| {
        try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[@backingInt(node)]);
    }
}

fn checkManualCaptureSlotReuse() !void {
    const source = "function* first(make, args) { return make().method(...args); } function* second(make, args) { return make().method(...args); }";
    const expression = "make().method(...args)";
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
    var transformer_value = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer_value.initSymbolIds(analyzer.symbol_ids.items);
    transformer_value.symbols = analyzer.symbols.items;
    transformer_value.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer_value.references = analyzer.references.items;
    transformer_value.scopes = analyzer.scopes.items;
    transformer_value.scope_maps = analyzer.scope_maps.items;
    transformer_value.scope_owner_map = analyzer.scope_owner_map;
    transformer_value.unresolved_references = &analyzer.unresolved_references;
    transformer_value.semantic_edit_enabled = true;
    var transformer = &transformer_value;
    var function_scopes: [2]ScopeId = undefined;
    var function_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        if (function_count == function_scopes.len) break;
        const function: ast_mod.NodeIndex = @fromBackingInt(@intCast(raw));
        function_scopes[function_count] = transformer.originalFunctionScope(function);
        function_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), function_count);

    var producer_ids: [2]u64 = undefined;
    var producer_spans: [2]token_mod.Span = undefined;
    var reference_nodes: [2][2]ast_mod.NodeIndex = undefined;
    for (function_scopes, 0..) |scope, index| {
        if (index == 1) transformer.temp_var_counter = 0;
        transformer.current_scope = scope;
        transformer.state_machine_depth = 1;
        const expression_node = try findExpressionNode(transformer, source, expression, .spread_call, index);
        _ = try ES2015Spread.lowerSpreadCall(transformer, transformer.ast.getNode(expression_node));
        const offset = index * 2;
        const first = transformer.pending_temp_producer_refs.items[offset];
        const second = transformer.pending_temp_producer_refs.items[offset + 1];
        try std.testing.expectEqual(first.temp_producer_id, second.temp_producer_id);
        try std.testing.expect(first.flags.write != second.flags.write);
        try expectPendingProducerIdMatchesAllocator(transformer, second);
        producer_ids[index] = first.temp_producer_id;
        producer_spans[index] = first.name_span;
        reference_nodes[index] = .{ first.node, second.node };
    }

    try std.testing.expectEqual(@as(usize, 4), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expect(producer_ids[0] != producer_ids[1]);
    try std.testing.expectEqual(producer_ids[1], transformer.temp_producer_id_by_counter.get(0).?);
    const reused_slot_span = transformer.temp_span_by_counter.get(0).?;
    try std.testing.expectEqual(producer_spans[1].start, reused_slot_span.start);
    try std.testing.expectEqual(producer_spans[1].end, reused_slot_span.end);
    try std.testing.expectEqualStrings(transformer.ast.getText(producer_spans[0]), transformer.ast.getText(producer_spans[1]));

    transformer.state_machine_depth = 0;
    for (function_scopes, producer_ids, producer_spans, 0..) |scope, producer_id, name_span, index| {
        const binding = try helpers.makeSyntheticBinding(transformer, name_span);
        try transformer.bindHoistedTempWithProducerIdentity(
            binding,
            name_span,
            name_span,
            transformer.nearestVarScope(scope),
            null,
            producer_id,
        );
        const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingReusedSlotBinding;
        try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(reference_nodes[index][0]));
        try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(reference_nodes[index][1]));
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);
    _ = try transformer.finishSemanticEdit();
}

test "#6004 manual ES2021 and spread captures carry deferred producer IDs across ten hostile inputs" {
    try checkDeferredManualCapture(
        "function* update(object, fallback) { yield object.value ??= fallback(); }",
        "object.value ??= fallback()",
        .nullish_assignment,
        false,
    );
    try checkDeferredManualCapture(
        "function* update(object, fallback) { yield object.value ??= fallback(); }",
        "object.value ??= fallback()",
        .nullish_assignment,
        false,
    );
    try checkDeferredManualCapture(
        "function* update(object, fallback) { if (object) { yield object.value ??= fallback(); } }",
        "object.value ??= fallback()",
        .nullish_assignment,
        false,
    );
    try checkDeferredManualCapture(
        "function* outer(object, fallback) { function inner() { return object.value ??= fallback(); } yield inner(); }",
        "object.value ??= fallback()",
        .nullish_assignment,
        false,
    );
    try checkDeferredManualCapture(
        "class Box { static result = object.value ??= fallback(); }",
        "object.value ??= fallback()",
        .nullish_assignment,
        true,
    );
    try checkDeferredManualCapture(
        "function* update(_a, object, fallback) { eval('_a'); yield object.value ??= fallback(); }",
        "object.value ??= fallback()",
        .nullish_assignment,
        false,
    );
    try checkDeferredManualCapture(
        "function* invoke(args) { yield getReceiver()[getKey()](...args); }",
        "getReceiver()[getKey()](...args)",
        .spread_call,
        false,
    );
    try checkDeferredManualCapture(
        "function* construct(args) { yield new (getConstructor())(...args); }",
        "new (getConstructor())(...args)",
        .spread_new,
        false,
    );
    try checkDeferredManualCapture(
        "function* outer(args) { function inner() { return getReceiver().method(...args); } yield inner(); }",
        "getReceiver().method(...args)",
        .spread_call,
        false,
    );
    try checkDeferredManualCapture(
        "class Box { static result = getReceiver().method(...args); }",
        "getReceiver().method(...args)",
        .spread_call,
        true,
    );
    try checkManualCaptureSlotReuse();
}
