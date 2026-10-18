const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const es_helpers = @import("es_helpers.zig");

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
    try std.testing.expect(transformer.temp_symbol_ids_by_counter.count() > 0);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer ids.deinit(allocator);
    var temp_iterator = transformer.temp_symbol_ids_by_counter.iterator();
    var total_reads: usize = 0;
    var total_writes: usize = 0;
    while (temp_iterator.next()) |entry| {
        const id = entry.value_ptr.*;
        try std.testing.expect(!ids.contains(id));
        try ids.put(allocator, id, {});
        try std.testing.expect(id >= source_symbol_count);
        try std.testing.expect(id < editor.symbols.items.len);
        const symbol = editor.symbols.items[id];
        try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
        const temp_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse
            return error.MissingProducerTempSpan;
        try std.testing.expectEqual(symbol.name.start, temp_span.start);
        try std.testing.expectEqual(symbol.name.end, temp_span.end);
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
    };
    for (cases) |source| try checkExactPrivateTemps(source);
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
    const deferred = try es_helpers.captureToTrackedTemp(&transformer, value, span);
    try std.testing.expect(deferred.symbol_id == null);
    try std.testing.expect(deferred.reference_scope.isNone());
    _ = try es_helpers.makeCapturedTempRef(&transformer, deferred, span, .{ .read = true });
    try std.testing.expectEqual(pending_before + 2, transformer.pending_temp_refs.items.len);
}
