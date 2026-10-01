const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const Transformer = @import("transformer.zig").Transformer;
const Tag = @import("../parser/ast.zig").Node.Tag;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;

test "#4819 Flow match temp binding and every emitted read get IDs during lowering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "// @flow\nmatch (input) { { payload: [const value], ...const rest } => value + Object.keys(rest).length, _ => input };";

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.is_flow = true;
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var match_node: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .flow_match_expression) {
            match_node = @enumFromInt(raw);
            break;
        }
    }
    const source_match = match_node orelse return error.TestUnexpectedResult;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();

    const lowered = try transformer.visitNode(source_match);
    const call = transformer.ast.getNode(lowered);
    try std.testing.expectEqual(Tag.call_expression, call.tag);
    const fn_expr: @TypeOf(source_match) = @enumFromInt(transformer.ast.extra_data.items[call.data.extra]);
    const function = transformer.ast.getNode(fn_expr);
    const params = transformer.ast.functionParamsList(function);
    try std.testing.expectEqual(@as(u32, 1), params.len);
    const parameter: @TypeOf(source_match) = @enumFromInt(transformer.ast.extra_data.items[params.start]);
    const parameter_id = transformer.getSymbolIdAt(parameter) orelse return error.TestUnexpectedResult;
    const function_scope = transformer.outputOwnedScope(fn_expr) orelse return error.TestUnexpectedResult;
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(SymbolKind.parameter, editor.symbols.items[@intCast(parameter_id)].kind);
    try std.testing.expectEqual(function_scope, editor.symbols.items[@intCast(parameter_id)].scope_id);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, lowered);
    var temp_reads: usize = 0;
    var function_scope_reads: usize = 0;
    var arm_scope_reads: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_a")) continue;
        const id = transformer.getSymbolIdAt(@enumFromInt(raw)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(parameter_id, id);
        var reference_found = false;
        for (editor.references.items) |reference| {
            if (reference.node_index != @as(@TypeOf(source_match), @enumFromInt(raw))) continue;
            try std.testing.expectEqual(parameter_id, @intFromEnum(reference.symbol_id));
            if (reference.scope_id == function_scope) function_scope_reads += 1;
            if (reference.scope_id != function_scope) {
                try std.testing.expectEqual(function_scope, editor.scopes.items[reference.scope_id.toIndex()].parent);
                arm_scope_reads += 1;
            }
            reference_found = true;
            break;
        }
        try std.testing.expect(reference_found);
        temp_reads += 1;
    }
    try std.testing.expect(temp_reads >= 3);
    try std.testing.expect(function_scope_reads > 0);
    try std.testing.expect(arm_scope_reads > 0);

    var registered_reads: usize = 0;
    for (editor.references.items) |reference| {
        if (@intFromEnum(reference.symbol_id) != parameter_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(reference.flags.declare);
            continue;
        }
        const raw = @intFromEnum(reference.node_index);
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, raw) != null);
        registered_reads += 1;
    }
    try std.testing.expectEqual(temp_reads, registered_reads);
}
