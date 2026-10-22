const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;
const Transformer = @import("transformer.zig").Transformer;
const es_helpers = @import("es_helpers.zig");
const parameter_environment = @import("parameter_environment.zig");

fn sameSpan(a: Span, b: Span) bool {
    return a.start == b.start and a.end == b.end;
}

fn checkRuntimeKeyNameTempIdentity(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_raw: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        if (function_raw != null) return error.MultipleTargetFunctionDeclarations;
        function_raw = @intCast(raw);
    }
    const target = function_raw orelse return error.MissingTargetFunction;
    const target_scope_raw = analyzer.scope_owner_map.get(target) orelse return error.MissingTargetScope;
    const target_scope: ScopeId = @fromBackingInt(@intCast(target_scope_raw));
    const target_span = parser.ast.nodes.items[target].span;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
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
    transformer.current_scope = target_scope;

    const key_expr = try es_helpers.makeNumericLiteral(&transformer, 7);
    const captured = try parameter_environment.captureRuntimeKey(&transformer, key_expr, target_span);
    const id = captured.temp.symbol_id orelse return error.MissingRuntimeKeyProducerSymbol;
    try std.testing.expectEqual(target_scope, captured.temp.reference_scope);
    try std.testing.expect(sameSpan(
        transformer.ast.getNode(captured.key).span,
        target_span,
    ));

    const write = transformer.ast.getNode(captured.key).data.binary.left;
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(write));

    var counter: ?u32 = null;
    var producer_ids = transformer.temp_symbol_ids_by_counter.iterator();
    while (producer_ids.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(id)) continue;
        if (counter != null) return error.DuplicateRuntimeKeyProducerCounter;
        counter = entry.key_ptr.*;
    }
    const producer_counter = counter orelse return error.MissingRuntimeKeyProducerCounter;
    const producer_span = transformer.temp_span_by_counter.get(producer_counter) orelse return error.MissingRuntimeKeyProducerSpan;
    const temp_producer_id = transformer.temp_producer_id_by_counter.get(producer_counter) orelse
        return error.MissingRuntimeKeyTempProducerId;
    try std.testing.expect(sameSpan(producer_span, captured.temp.span));

    // This consumer must use the captured handle even if the span-keyed map is gone.
    transformer.synthetic_temp_symbol_ids.clearRetainingCapacity();
    const value = try es_helpers.makeNumericLiteral(&transformer, 1);
    const named = try parameter_environment.nameByTemp(&transformer, value, captured.temp, null, target_span);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
    _ = named;

    const binding = try es_helpers.makeSyntheticBinding(&transformer, captured.temp.span);
    try transformer.bindHoistedTempWithProducerIdentity(
        binding,
        captured.temp.span,
        target_span,
        target_scope,
        id,
        temp_producer_id,
    );
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(binding));

    const editor = if (transformer.semantic_editor) |*current| current else return error.MissingSemanticEditor;
    const symbol = editor.symbols.items[@backingInt(id)];
    try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
    try std.testing.expectEqual(target_scope, symbol.scope_id);
    try std.testing.expect(sameSpan(symbol.name, captured.temp.span));

    var reads: usize = 0;
    var writes: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != @backingInt(id) or reference.flags.declare) continue;
        try std.testing.expectEqual(target_scope, reference.scope_id);
        try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expect(sameSpan(node.data.string_ref, captured.temp.span));
        if (reference.flags.read) reads += 1;
        if (reference.flags.write) writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 1), writes);
}

test "#4819 runtime computed-key name capture retains exact temp identity" {
    const cases = [_][]const u8{
        "function target(fn, key) { return fn; }",
        "const _a = 99; function target(fn, key) { return [fn, _a]; }",
        "function target(fn, key) { var _b = 3; return [fn, _b]; }",
        "function target(fn, key) { { let _c = 4; } return fn; }",
        "function target(fn, key) { return () => fn; }",
        "function target(fn, key) { eval('typeof _a'); return fn; }",
        "function target(fn, key) { try { throw 1; } catch (_a) { return fn; } }",
        "function target(fn, key) { return { get [key]() { return fn; } }; }",
        "function target(fn, key) { return { set [key](value) { fn(value); } }; }",
        "function target(fn, key) { return { [key]: function nested() { return fn; } }; }",
    };
    for (cases) |source| try checkRuntimeKeyNameTempIdentity(source);
}
