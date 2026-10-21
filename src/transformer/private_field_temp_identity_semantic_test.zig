const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const es_helpers = @import("es_helpers.zig");

fn isGeneratedTempName(name: []const u8) bool {
    if (name.len < 2 or name[0] != '_' or name[1] < 'a' or name[1] > 'z') return false;
    for (name[2..]) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn checkExactPrivateTemps(source: []const u8) !void {
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
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer ids.deinit(allocator);
    var temp_iterator = transformer.temp_symbol_ids_by_counter.valueIterator();
    while (temp_iterator.next()) |id| try ids.put(allocator, id.*, {});
    var bound_iterator = transformer.bound_temp_symbols.valueIterator();
    while (bound_iterator.next()) |id| try ids.put(allocator, id.*, {});
    var producer_iterator = transformer.temp_symbols_by_producer_id.valueIterator();
    while (producer_iterator.next()) |id| try ids.put(allocator, id.*, {});
    for (editor.symbols.items, 0..) |symbol, raw_id| {
        if (raw_id < source_symbol_count or symbol.kind != SymbolKind.variable_var or
            !isGeneratedTempName(symbol.synthetic_name)) continue;
        try ids.put(allocator, @intCast(raw_id), {});
    }
    if (ids.count() == 0) {
        std.debug.print("private-field identity fixture produced no temp SymbolId: {s}\n", .{source});
        return error.MissingCapturedTempIdentity;
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);

    var total_reads: usize = 0;
    var total_writes: usize = 0;
    var temp_ids = ids.iterator();
    while (temp_ids.next()) |entry| {
        const id = entry.key_ptr.*;
        try std.testing.expect(id >= source_symbol_count);
        try std.testing.expect(id < editor.symbols.items.len);
        const symbol = editor.symbols.items[id];
        try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
        try std.testing.expectEqualStrings(symbol.synthetic_name, transformer.ast.getText(symbol.name));
        try std.testing.expect(!symbol.scope_id.isNone());

        var reads: usize = 0;
        var writes: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) != id) continue;
            try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
            if (reference.flags.read) reads += 1;
            if (reference.flags.write) writes += 1;
        }
        try std.testing.expect(writes > 0);
        total_reads += reads;
        total_writes += writes;
    }
    try std.testing.expect(total_reads > 0);
    try std.testing.expect(total_writes >= ids.count());

    const edited = (try transformer.finishSemanticEdit()).?;
    var ids_iterator = ids.iterator();
    while (ids_iterator.next()) |entry| {
        const id = entry.key_ptr.*;
        var exact_bindings: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
            if (edited.symbol_ids[raw] == id) exact_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_bindings);
        for (edited.references) |reference| {
            if (reference.node_index.isNone() or @backingInt(reference.symbol_id) != id) continue;
            try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(reference.node_index)]);
        }
    }
}

fn checkDeferredCaptureProducerSlotReuse(source: []const u8) !void {
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
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var functions: [2]NodeIndex = undefined;
    var function_count: usize = 0;
    var values: [2]NodeIndex = undefined;
    var value_count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration and function_count < functions.len) {
            functions[function_count] = @fromBackingInt(@intCast(raw));
            function_count += 1;
        }
        if (node.tag == .numeric_literal and value_count < values.len) {
            values[value_count] = @fromBackingInt(@intCast(raw));
            value_count += 1;
        }
    }
    if (function_count != functions.len or value_count != values.len) return error.MissingCaptureFixtures;
    const scope_a = transformer.originalFunctionScope(functions[0]);
    const scope_b = transformer.originalFunctionScope(functions[1]);
    if (scope_a.isNone() or scope_b.isNone() or scope_a == scope_b) return error.MissingDistinctCaptureScopes;

    // Both producers reuse the same allocator slot in different owners. Their
    // printed names match, but their stable producer handles and string spans do not.
    transformer.current_scope = scope_a;
    transformer.state_machine_depth = 1;
    const value_a_span = parser.ast.getNode(values[0]).span;
    const capture_a = try es_helpers.captureToTrackedTemp(&transformer, values[0], value_a_span);
    const producer_a = capture_a.temp_producer_id orelse return error.MissingFirstTempProducerId;
    const slot_a = capture_a.temp_counter_index orelse return error.MissingFirstTempSlot;
    const write_a = transformer.ast.getNode(capture_a.paren_assign).data.binary.left;
    const read_a = try es_helpers.makeCapturedTempRef(&transformer, capture_a, value_a_span, .{ .read = true });

    transformer.temp_var_counter = slot_a;
    transformer.current_scope = scope_b;
    const value_b_span = parser.ast.getNode(values[1]).span;
    const capture_b = try es_helpers.captureToTrackedTemp(&transformer, values[1], value_b_span);
    const producer_b = capture_b.temp_producer_id orelse return error.MissingSecondTempProducerId;
    const slot_b = capture_b.temp_counter_index orelse return error.MissingSecondTempSlot;
    const write_b = transformer.ast.getNode(capture_b.paren_assign).data.binary.left;
    const read_b = try es_helpers.makeCapturedTempRef(&transformer, capture_b, value_b_span, .{ .read = true });

    try std.testing.expectEqual(slot_a, slot_b);
    try std.testing.expect(producer_a != producer_b);
    try std.testing.expectEqualStrings(transformer.ast.getText(capture_a.span), transformer.ast.getText(capture_b.span));
    try std.testing.expect(capture_a.span.start != capture_b.span.start or capture_a.span.end != capture_b.span.end);
    try std.testing.expectEqual(@as(usize, 4), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    transformer.state_machine_depth = 0;
    const binding_b = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, capture_b.span);
    try transformer.bindHoistedTempWithProducerIdentity(
        binding_b,
        capture_b.span,
        value_b_span,
        scope_b,
        null,
        producer_b,
    );
    const binding_a = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, capture_a.span);
    try transformer.bindHoistedTempWithProducerIdentity(
        binding_a,
        capture_a.span,
        value_a_span,
        scope_a,
        null,
        producer_a,
    );

    const id_a = transformer.getSymbolIdAt(binding_a) orelse return error.MissingFirstBoundTemp;
    const id_b = transformer.getSymbolIdAt(binding_b) orelse return error.MissingSecondBoundTemp;
    try std.testing.expect(id_a != id_b);
    try std.testing.expectEqual(@as(?u32, id_a), transformer.temp_symbols_by_producer_id.get(producer_a));
    try std.testing.expectEqual(@as(?u32, id_b), transformer.temp_symbols_by_producer_id.get(producer_b));
    try std.testing.expectEqual(@as(?u32, id_a), transformer.getSymbolIdAt(write_a));
    try std.testing.expectEqual(@as(?u32, id_a), transformer.getSymbolIdAt(read_a));
    try std.testing.expectEqual(@as(?u32, id_b), transformer.getSymbolIdAt(write_b));
    try std.testing.expectEqual(@as(?u32, id_b), transformer.getSymbolIdAt(read_b));
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    try std.testing.expectEqual(scope_a, editor.symbols.items[id_a].scope_id);
    try std.testing.expectEqual(scope_b, editor.symbols.items[id_b].scope_id);
    const write_reference_a = (try editor.referenceForNode(write_a)) orelse return error.MissingFirstWriteReference;
    const write_reference_b = (try editor.referenceForNode(write_b)) orelse return error.MissingSecondWriteReference;
    const reference_a = (try editor.referenceForNode(read_a)) orelse return error.MissingFirstReadReference;
    const reference_b = (try editor.referenceForNode(read_b)) orelse return error.MissingSecondReadReference;
    try std.testing.expectEqual(id_a, @backingInt(write_reference_a.symbol_id));
    try std.testing.expectEqual(id_b, @backingInt(write_reference_b.symbol_id));
    try std.testing.expectEqual(id_a, @backingInt(reference_a.symbol_id));
    try std.testing.expectEqual(id_b, @backingInt(reference_b.symbol_id));
    try std.testing.expectEqual(scope_a, write_reference_a.scope_id);
    try std.testing.expectEqual(scope_b, write_reference_b.scope_id);
    try std.testing.expectEqual(scope_a, reference_a.scope_id);
    try std.testing.expectEqual(scope_b, reference_b.scope_id);
    try std.testing.expect(write_reference_a.flags.write and !write_reference_a.flags.read);
    try std.testing.expect(write_reference_b.flags.write and !write_reference_b.flags.read);
    try std.testing.expect(reference_a.flags.read and !reference_a.flags.write);
    try std.testing.expect(reference_b.flags.read and !reference_b.flags.write);
}

test "#4819 private-field temps carry producer SymbolId through reads and hoists" {
    const cases = [_][]const u8{
        // Nullish assignment captures the old private-field value.
        "class Box { #value = null; update(rhs) { return this.#value ??= rhs; } }\n",
        // Prefix and postfix updates both reuse the captured value temp.
        "class Box { #value = 1; update() { return ++this.#value; } }\n",
        "class Box { #value = 1; update() { return this.#value++; } }\n",
        // Accessor assignment preserves the assigned expression value.
        "class Box { get #value() { return 0; } set #value(value) {} update(value) { return this.#value = value; } }\n",
        // A private accessor's logical assignment reads its getter only once.
        "class Box { get #value() { return 0; } set #value(value) {} update(rhs) { return this.#value ??= rhs(); } }\n",
        // Effectful receiver plus nullish assignment.
        "function getBox(value) { return value; } class Box { #value = null; update(rhs) { return getBox(this).#value ??= rhs(); } }\n",
        // A temp is created under a nested function owner.
        "function getBox(value) { return value; } class Box { #value = 0; update() { return (() => getBox(this).#value++)(); } }\n",
        // The same operations occur in a try/catch scope.
        "function getBox(value) { return value; } class Box { #value = null; update(rhs) { try { return getBox(this).#value ??= rhs(); } catch (error) { return this.#value++; } } }\n",
        // Static private accessor update uses receiver and value captures.
        "class Box { static get #value() { return 1; } static set #value(value) {} static update() { return this.#value++; } }\n",
        // Direct eval and a user temp-like name are hostile to spelling lookup.
        "class Box { #value = null; update(flag, rhs) { if (flag) { eval('var _a'); return this.#value ??= rhs(); } return (() => this.#value++)(); } }\n",
        // Deferred async owner: the assignment's write and later read share one capture.
        "class Box { #value = null; async update(rhs) { return this.#value ??= await rhs(); } }\n",
        // Compound assignment spans a suspension point between read and write.
        "class Box { #value = 1; async update(rhs) { return this.#value += await rhs(); } }\n",
        // Prefix update inside an async method must retain the result temp.
        "class Box { #value = 1; async update() { return ++this.#value; } }\n",
        // Postfix update inside an async method must keep old and new values distinct.
        "class Box { #value = 1; async update() { return this.#value++; } }\n",
        // Logical-or assignment has a conditional write after suspension.
        "class Box { #value = 0; async update(rhs) { return this.#value ||= await rhs(); } }\n",
        // Logical-and assignment has a different conditional branch shape.
        "class Box { #value = 1; async update(rhs) { return this.#value &&= await rhs(); } }\n",
        // Static accessor and a shadowing temp-like source binding.
        "class Box { static get #value() { return 1; } static set #value(v) {} static async update(_a) { return this.#value += await _a; } }\n",
        // Nested async arrow adds another generated owner around the capture.
        "class Box { #value = 0; async update(rhs) { return await (async () => this.#value ??= await rhs())(); } }\n",
        // Try/finally keeps references live across control-flow extraction.
        "class Box { #value = null; async update(rhs) { try { return this.#value ??= await rhs(); } finally { this.#value++; } } }\n",
        // Async generator resumes the capture after yield and then writes it back.
        "class Box { #value = 1; async *update(rhs) { const old = this.#value++; yield old; this.#value += await rhs(); } }\n",
    };
    for (cases) |source| try checkExactPrivateTemps(source);
}

test "#4819 deferred captured temps keep producer identity when allocator slots are reused" {
    const cases = [_][]const u8{
        "function first() { return 101; } function second() { return 102; }\n",
        "let _a; function first() { const value = 201; return value; } function second() { return 202; }\n",
        "let _a, _b; function first() { return 301; } function second() { const value = 302; return value; }\n",
        "eval('var _a'); function first() { return 401; } function second() { return -402; }\n",
        "function first() { try { return 501; } finally {} } function second() { try { return 502; } finally {} }\n",
        "function first() { { const value = 601; return value; } } function second() { { const value = 602; return value; } }\n",
        "function first(value = 701) { return value; } function second(value = 702) { return value; }\n",
        "function first() { for (const value of values) { return 801; } } function second() { for (const value of values) { return 802; } }\n",
        "function first() { return -901; } function second() { return +902; }\n",
        "function first() { const value = 1001; return value; } function second() { const value = 1002; return value; }\n",
    };
    for (cases) |source| try checkDeferredCaptureProducerSlotReuse(source);
}

test "captured temp references use the retained producer handle when lookup data is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function host() { return 1; }\n";

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var numeric_node: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .numeric_literal) {
            numeric_node = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const value = numeric_node orelse return error.MissingNumericInput;
    const span = parser.ast.getNode(value).span;

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
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
    transformer.current_scope = transformer.programScope();
    const capture = try es_helpers.captureToTrackedTemp(&transformer, value, span);
    const id = capture.symbol_id orelse return error.MissingCapturedTempSymbolId;
    try std.testing.expect(!capture.reference_scope.isNone());
    var recorded_producer_id = false;
    var temp_ids = transformer.temp_symbol_ids_by_counter.iterator();
    while (temp_ids.next()) |entry| {
        if (entry.value_ptr.* == @backingInt(id)) recorded_producer_id = true;
    }
    try std.testing.expect(recorded_producer_id);
    const assignment = transformer.ast.getNode(capture.paren_assign);
    const write = assignment.data.binary.left;
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(write));

    // Removing the spelling index must not affect consumers that hold the
    // producer's exact SymbolId and output reference scope.
    transformer.synthetic_temp_symbol_ids.clearRetainingCapacity();
    const read = try es_helpers.makeCapturedTempRef(&transformer, capture, span, .{ .read = true });
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(read));

    const editor = if (transformer.semantic_editor) |*value_editor| value_editor else return error.MissingSemanticEditor;
    try std.testing.expect(editor.symbolVisibleFrom(id, capture.reference_scope));
    var reads: usize = 0;
    var writes: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.symbol_id != id) continue;
        if (reference.flags.read) reads += 1;
        if (reference.flags.write) writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 1), writes);

    // When the callback owner is not available yet, preserve the deferred
    // handoff instead of manufacturing an identity in the current scope.
    transformer.state_machine_depth = 1;
    const pending_before = transformer.pending_temp_refs.items.len;
    const producer_pending_before = transformer.pending_temp_producer_refs.items.len;
    const deferred = try es_helpers.captureToTrackedTemp(&transformer, value, span);
    try std.testing.expect(deferred.symbol_id == null);
    try std.testing.expect(deferred.reference_scope.isNone());
    const deferred_producer_id = deferred.temp_producer_id orelse return error.MissingDeferredTempProducerId;
    const deferred_assignment = transformer.ast.getNode(deferred.paren_assign);
    const deferred_write = deferred_assignment.data.binary.left;
    const deferred_read = try es_helpers.makeCapturedTempRef(&transformer, deferred, span, .{ .read = true });
    try std.testing.expectEqual(pending_before, transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(producer_pending_before + 2, transformer.pending_temp_producer_refs.items.len);
    for (transformer.pending_temp_producer_refs.items[producer_pending_before..]) |pending| {
        try std.testing.expectEqual(deferred_producer_id, pending.temp_producer_id);
        try std.testing.expectEqual(deferred.span.start, pending.name_span.start);
        try std.testing.expectEqual(deferred.span.end, pending.name_span.end);
    }

    // The hoist can bind the deferred references directly from their stable
    // producer ID after the callback owner becomes available.
    transformer.state_machine_depth = 0;
    const deferred_binding = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, deferred.span);
    try transformer.bindHoistedTempWithProducerIdentity(
        deferred_binding,
        deferred.span,
        span,
        transformer.programScope(),
        null,
        deferred_producer_id,
    );
    const deferred_id = transformer.getSymbolIdAt(deferred_binding) orelse return error.MissingBoundDeferredTempId;
    try std.testing.expectEqual(@as(?u32, deferred_id), transformer.temp_symbols_by_producer_id.get(deferred_producer_id));
    try std.testing.expectEqual(@as(?u32, deferred_id), transformer.getSymbolIdAt(deferred_write));
    try std.testing.expectEqual(@as(?u32, deferred_id), transformer.getSymbolIdAt(deferred_read));
    try std.testing.expectEqual(producer_pending_before, transformer.pending_temp_producer_refs.items.len);
}
