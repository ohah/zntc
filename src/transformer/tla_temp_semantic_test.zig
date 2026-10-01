const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;

test "#4819 top-level-await result binding has a semantic SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const _a = 'user'; console.log(_b); await Promise.resolve();";

    var scanner = try Scanner.init(allocator, source);
    scanner.is_module = true;
    var parser = Parser.init(allocator, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const source_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = .{ .top_level_await = true },
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
    const edited = (try transformer.finishSemanticEdit()).?;
    var tla_result_count: usize = 0;
    for (edited.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, index| {
        if (symbol.synthetic_name.len == 0 or !std.mem.startsWith(u8, symbol.synthetic_name, "_")) continue;
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
        try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, "_a"));
        try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, "_b"));
        var binding_count: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
            if (edited.symbol_ids[raw] == @as(?u32, @intCast(index))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        tla_result_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), tla_result_count);
}
