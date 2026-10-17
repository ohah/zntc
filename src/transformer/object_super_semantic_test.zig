const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const ast_mod = @import("../parser/ast.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

test "#4819 lowered default object-super home temp reserves and reuses its function SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function make(input = {
        \\  __proto__: this.base,
        \\  receiver: this,
        \\  method() { return super.value + 2; }
        \\}) {
        \\  return input.method.call(input.receiver);
        \\}
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?ScopeId = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: ast_mod.NodeIndex = @enumFromInt(entry.key_ptr.*);
        const node = parser.ast.getNode(owner);
        if (node.tag != .function_declaration) continue;
        const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone() or !std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(name).data.string_ref), "make")) continue;
        function_scope = @enumFromInt(entry.value_ptr.*);
        break;
    }
    const expected_scope = function_scope orelse return error.MissingFunctionScope;
    const source_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
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
    var home_id: ?SymbolId = null;
    for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, raw_id| {
        if (symbol.kind == .variable_var and std.mem.eql(u8, symbol.synthetic_name, "_a")) {
            try std.testing.expect(home_id == null);
            home_id = @enumFromInt(@as(u32, @intCast(raw_id)));
        }
    }
    const id = home_id orelse return error.MissingObjectHomeSymbol;
    const symbol = editor.symbols.items[@intFromEnum(id)];
    try std.testing.expectEqual(@intFromEnum(expected_scope), @intFromEnum(symbol.scope_id));
    try std.testing.expect(!transformer.pending_temp_ref_chains.contains(symbol.name.start));

    var live_reference_count: usize = 0;
    var live_read_count: usize = 0;
    var live_write_count: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.symbol_id != id or reference.node_index.isNone()) continue;
        try std.testing.expect(editor.symbolVisibleFrom(id, reference.scope_id));
        try std.testing.expect(reference.flags.read != reference.flags.write);
        if (reference.flags.read) live_read_count += 1;
        if (reference.flags.write) live_write_count += 1;
        live_reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live_reference_count);
    try std.testing.expectEqual(@as(usize, 1), live_read_count);
    try std.testing.expectEqual(@as(usize, 1), live_write_count);

    const edited = (try transformer.finishSemanticEdit()).?;
    var binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == @as(?u32, @intCast(@intFromEnum(id)))) binding_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);

    var reference_count: usize = 0;
    for (edited.references) |reference| {
        if (reference.symbol_id == id and !reference.node_index.isNone()) reference_count += 1;
    }
    try std.testing.expectEqual(live_reference_count, reference_count);
}
