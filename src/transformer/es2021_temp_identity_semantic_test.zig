const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

fn checkExactES2021MemberCapture(
    source: []const u8,
    expect_nested_reference_scope: bool,
    forbidden_temp_name: ?[]const u8,
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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    _ = try transformer.transform();
    try std.testing.expect(transformer.temp_symbol_ids_by_counter.count() > 0);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var producer_ids: std.ArrayList(u32) = .empty;
    var temp_symbol_iterator = transformer.temp_symbol_ids_by_counter.iterator();
    while (temp_symbol_iterator.next()) |counter_entry| {
        const id: u32 = counter_entry.value_ptr.*;
        const counter_name = transformer.temp_span_by_counter.get(counter_entry.key_ptr.*) orelse
            return error.MissingProducerTempSlot;
        try std.testing.expect(id < editor.symbols.items.len);
        try std.testing.expect(id >= source_symbol_count);
        const symbol = editor.symbols.items[id];
        try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
        try std.testing.expectEqual(symbol.name.start, counter_name.start);
        try std.testing.expectEqual(symbol.name.end, counter_name.end);
        var reads: usize = 0;
        var writes: usize = 0;
        var nested_scope_references: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) != id) continue;
            try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
            if (reference.scope_id != symbol.scope_id) nested_scope_references += 1;
            if (reference.flags.read) reads += 1;
            if (reference.flags.write) writes += 1;
        }
        try std.testing.expect(!symbol.scope_id.isNone());
        if (forbidden_temp_name) |name|
            try std.testing.expect(!std.mem.eql(u8, name, editor.ast.getText(symbol.name)));
        try std.testing.expectEqual(@as(usize, 1), reads);
        try std.testing.expectEqual(@as(usize, 1), writes);
        if (expect_nested_reference_scope)
            try std.testing.expect(nested_scope_references > 0)
        else
            try std.testing.expectEqual(@as(usize, 0), nested_scope_references);
        try producer_ids.append(allocator, id);
    }
    try std.testing.expect(producer_ids.items.len > 0);

    const edited = (try transformer.finishSemanticEdit()).?;
    for (producer_ids.items) |id| {
        var exact_bindings: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
            if (edited.symbol_ids[raw]) |symbol_id| {
                if (symbol_id == id) exact_bindings += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), exact_bindings);
        for (edited.references) |reference| {
            if (reference.node_index.isNone() or @backingInt(reference.symbol_id) != id) continue;
            try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(reference.node_index)]);
        }
    }
}

test "#4819 ES2021 ??= member temp keeps producer identity across hostile owner shapes" {
    // Distinct inputs pressure computed/static keys, side effects, nested scopes,
    // all three function forms, super, top-level hoisting, direct eval, and
    // user-name collision handling.
    try checkExactES2021MemberCapture(
        "function getObject() { return { value: undefined }; }\n" ++
            "function nextKey() { return 'value'; }\n" ++
            "function rhs() { return 5; }\n" ++
            "export function update() { return getObject()[nextKey()] ??= rhs(); }\n",
        false,
        null,
    );
    try checkExactES2021MemberCapture(
        "function nextKey() { return 'slot'; }\n" ++
            "function rhs() { return 5; }\n" ++
            "export function update(object) { return object[nextKey()] ??= rhs(); }\n",
        false,
        null,
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "export function update(object) { if (object) { return object.value ??= rhs(); } return 0; }\n",
        true,
        null,
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "export function update(object, keys) { for (const key of keys) { object[key] ??= rhs(); } return object; }\n",
        true,
        null,
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "export function update(object, key) { return (() => object[key] ??= rhs())(); }\n",
        false,
        null,
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "export class Box { update() { return this.value ??= rhs(); } }\n",
        false,
        null,
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "class Base { get value() { return undefined; } set value(v) {} }\n" ++
            "export class Box extends Base { update() { return super.value ??= rhs(); } }\n",
        false,
        null,
    );
    try checkExactES2021MemberCapture(
        "function getObject() { return { value: undefined }; }\n" ++
            "function nextKey() { return 'value'; }\n" ++
            "function rhs() { return 5; }\n" ++
            "export const result = getObject()[nextKey()] ??= rhs();\n",
        false,
        null,
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "export function update(object, key) { eval('_a'); return object[key] ??= rhs(); }\n",
        false,
        "_a",
    );
    try checkExactES2021MemberCapture(
        "function rhs() { return 5; }\n" ++
            "export function update(_a, object, key) { return object[key] ??= rhs(); }\n",
        false,
        "_a",
    );
}
