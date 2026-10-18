const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Span = @import("../lexer/token.zig").Span;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const es_helpers = @import("es_helpers.zig");
const ast_walk = @import("../parser/ast_walk.zig");

fn sameSpan(a: Span, b: Span) bool {
    return a.start == b.start and a.end == b.end;
}

fn findComputedObjectSpan(ast: anytype) !Span {
    for (ast.nodes.items) |node| {
        if (node.tag != .object_expression) continue;
        const members = ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
        for (members) |raw| {
            const member = ast.getNode(@fromBackingInt(@intCast(raw)));
            var key_idx: ast_mod.NodeIndex = .none;
            switch (member.tag) {
                .object_property => key_idx = member.data.binary.left,
                .method_definition => {
                    const me = member.data.extra;
                    key_idx = @fromBackingInt(@intCast(ast.extra_data.items[me + ast_mod.MethodExtra.key]));
                },
                else => {},
            }
            if (key_idx.isNone()) continue;
            if (ast.getNode(key_idx).tag == .computed_property_key) return node.span;
        }
    }
    return error.MissingComputedObjectLiteral;
}

fn checkObjectComputedTempIdentity(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const object_span = try findComputedObjectSpan(&parser.ast);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
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
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;

    const output_root = try transformer.transform();
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var producer_count: usize = 0;
    var producer_id: ?u32 = null;
    var producer_counter: ?u32 = null;
    var temp_iterator = transformer.temp_symbol_ids_by_counter.iterator();
    while (temp_iterator.next()) |entry| {
        const id = entry.value_ptr.*;
        if (id >= editor.symbols.items.len) return error.InvalidProducerSymbolId;
        if (!sameSpan(editor.symbols.items[id].declaration_span, object_span)) continue;
        producer_count += 1;
        // The object memo is reserved before lowering property values. A
        // runtime-key name capture may reserve another temp with the same
        // declaration span, so select the first producer slot here.
        if (producer_counter) |existing| {
            if (entry.key_ptr.* < existing) {
                producer_id = id;
                producer_counter = entry.key_ptr.*;
            }
        } else {
            producer_id = id;
            producer_counter = entry.key_ptr.*;
        }
    }
    try std.testing.expect(producer_count > 0);

    const id = producer_id orelse return error.MissingObjectTempProducerSymbol;
    const counter = producer_counter orelse return error.MissingObjectTempProducerSlot;
    const temp_span = transformer.temp_span_by_counter.get(counter) orelse return error.MissingObjectTempSpan;
    const symbol = editor.symbols.items[id];
    try std.testing.expect(id >= source_symbol_count);
    try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
    try std.testing.expectEqual(temp_span.start, symbol.name.start);
    try std.testing.expectEqual(temp_span.end, symbol.name.end);
    try std.testing.expect(!symbol.scope_id.isNone());

    var read_count: usize = 0;
    var write_count: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != id) continue;
        try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
        if (reference.flags.read) read_count += 1;
        if (reference.flags.write) write_count += 1;
    }
    try std.testing.expect(read_count > 0);
    try std.testing.expect(write_count > 0);

    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, output_root);
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
    _ = root;
}

test "#4819 object computed-key temps preserve producer identity across hostile scopes" {
    const cases = [_][]const u8{
        "function make(key) { return { before: 0, [key]: 1, after: 2 }; }",
        "let calls = 0; function next() { calls++; return 'x'; } const value = { [next()]: 1, [next()]: 2 };",
        "const _a = 7; function make(key) { return { before: 0, [key]: _a, after: 2 }; }",
        "function outer(key) { return (() => ({ [key]: 1, after: 2 }))(); }",
        "function make(key) { return { get [key]() { return 1; }, plain: 2 }; }",
        "function make(key) { return { set [key](value) { this.saved = value; }, plain: 2 }; }",
        "function make(key) { eval('var _a'); return { [key]: 1, after: 2 }; }",
        "function make(key) { try { return { [key]: 1 }; } catch (error) { return error; } }",
        "function make(key) { return { [key]: function value() { return key; }, after: 2 }; }",
        "const _a = 3; function make(key) { return { [key]() { return _a; }, [key]: _a }; }",
    };
    for (cases) |source| try checkObjectComputedTempIdentity(source);
}

test "#4819 object computed-key temp handle survives name lookup loss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const value = 1; function inner() {}");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const program_scope_raw = analyzer.scope_owner_map.get(@backingInt(root)) orelse return error.MissingProgramScope;
    const program_scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(@intCast(program_scope_raw));

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = program_scope;

    const capture = try es_helpers.reserveTrackedTempIdentity(&transformer, Span.EMPTY);
    const id = capture.symbol_id orelse return error.MissingProducerSymbolId;
    try std.testing.expectEqual(program_scope, capture.reference_scope);
    transformer.synthetic_temp_symbol_ids.clearRetainingCapacity();
    const write = try es_helpers.makeTempRefFromIdentity(&transformer, capture, Span.EMPTY, .{ .write = true });
    const read = try es_helpers.makeTempRefFromIdentity(&transformer, capture, Span.EMPTY, .{ .read = true });
    try std.testing.expectEqual(@backingInt(id), transformer.getSymbolIdAt(write) orelse return error.MissingWriteSymbolId);
    try std.testing.expectEqual(@backingInt(id), transformer.getSymbolIdAt(read) orelse return error.MissingReadSymbolId);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    try std.testing.expectEqual(id, (try editor.referenceForNode(write) orelse return error.MissingWriteReference).symbol_id);
    try std.testing.expectEqual(id, (try editor.referenceForNode(read) orelse return error.MissingReadReference).symbol_id);
    try std.testing.expectEqual(program_scope, (try editor.referenceForNode(write) orelse return error.MissingWriteReferenceScope).scope_id);
    try std.testing.expectEqual(program_scope, (try editor.referenceForNode(read) orelse return error.MissingReadReferenceScope).scope_id);
}
