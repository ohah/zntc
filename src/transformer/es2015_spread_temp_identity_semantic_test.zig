const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

fn checkExactSpreadTemp(
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
    try std.testing.expectEqual(@as(usize, 1), transformer.temp_symbol_ids_by_counter.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    var temp_symbol_iterator = transformer.temp_symbol_ids_by_counter.iterator();
    const counter_entry = temp_symbol_iterator.next().?;
    const id: u32 = counter_entry.value_ptr.*;
    const temp_span = transformer.temp_span_by_counter.get(counter_entry.key_ptr.*) orelse
        return error.MissingProducerTempSlot;
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    try std.testing.expect(id < editor.symbols.items.len);
    try std.testing.expect(id >= source_symbol_count);
    try std.testing.expectEqual(SymbolKind.variable_var, editor.symbols.items[id].kind);
    try std.testing.expectEqual(editor.symbols.items[id].name.start, temp_span.start);
    try std.testing.expectEqual(editor.symbols.items[id].name.end, temp_span.end);

    const binding_scope = editor.symbols.items[id].scope_id;
    try std.testing.expect(!binding_scope.isNone());
    const temp_name = editor.ast.getText(editor.symbols.items[id].name);
    if (forbidden_temp_name) |name| try std.testing.expect(!std.mem.eql(u8, name, temp_name));

    var reads: usize = 0;
    var writes: usize = 0;
    var nested_scope_references: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != id) continue;
        try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
        if (reference.scope_id != binding_scope) nested_scope_references += 1;
        if (reference.flags.read) reads += 1;
        if (reference.flags.write) writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 1), writes);
    if (expect_nested_reference_scope)
        try std.testing.expect(nested_scope_references > 0)
    else
        try std.testing.expectEqual(@as(usize, 0), nested_scope_references);

    const edited = (try transformer.finishSemanticEdit()).?;
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

test "#4819 ES2015 spread captures keep producer identity through reads and hoist" {
    // Distinct inputs cover call receiver and constructor-callee captures,
    // computed member side effects, nested owners, program hoisting, eval, and
    // user-name collisions.
    try checkExactSpreadTemp(
        "function getReceiver() { return { method() {} }; }\n" ++
            "export function invoke(args) { return getReceiver().method(...args); }\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function getReceiver() { return { method() {} }; }\n" ++
            "function nextKey() { return 'method'; }\n" ++
            "export function invoke(args) { return getReceiver()[nextKey()](...args); }\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function getReceiver() { return { method() {} }; }\n" ++
            "export function invoke(flag, args) { if (flag) { return getReceiver().method(...args); } return 0; }\n",
        true,
        null,
    );
    try checkExactSpreadTemp(
        "function getReceiver() { return { method() {} }; }\n" ++
            "export function invoke(args) { try { return getReceiver().method(...args); } catch (error) { return error; } }\n",
        true,
        null,
    );
    try checkExactSpreadTemp(
        "function getReceiver() { return { method() {} }; }\n" ++
            "export function invoke(args) { return (() => getReceiver().method(...args))(); }\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function getContainer() { return { Ctor: class {} }; }\n" ++
            "export function construct(args) { return new getContainer().Ctor(...args); }\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function getContainer() { return { Ctor: class {} }; }\n" ++
            "function nextKey() { return 'Ctor'; }\n" ++
            "export function construct(args) { return new getContainer()[nextKey()](...args); }\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function makeCtor() { return class {}; }\n" ++
            "export function construct(args) { return new (makeCtor())(...args); }\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function getContainer() { return { Ctor: class {} }; }\n" ++
            "export const instance = new getContainer().Ctor(...globalThis.args);\n",
        false,
        null,
    );
    try checkExactSpreadTemp(
        "function getReceiver() { return { method() {} }; }\n" ++
            "export function invoke(_a, args) { eval('_a'); return getReceiver().method(...args); }\n",
        false,
        "_a",
    );
}
