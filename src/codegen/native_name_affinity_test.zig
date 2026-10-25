const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Codegen = @import("codegen.zig").Codegen;
const Metadata = @import("codegen.zig").LinkingMetadata;

test "native Annex B output names follow the exact outer variable without merging lexical identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "var read=1;{function read(){return 42}console.log({read}.read())}");
    var parser = Parser.init(allocator, &scanner);
    const root = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var lexical: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, index| if (!symbol.annex_b_alias.variable.isNone()) {
        lexical = @intCast(index);
    };
    const local = lexical orelse return error.MissingNativeAlias;
    const variable = @backingInt(analyzer.symbols.items[local].annex_b_alias.variable);
    try std.testing.expect(local != variable);
    var metadata: Metadata = .{
        .skip_nodes = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len),
        .renames = .empty,
        .final_exports = null,
        .symbol_ids = analyzer.symbol_ids.items,
        .allocator = allocator,
    };
    try metadata.renames.put(allocator, variable, "chosen_outer");
    try metadata.renames.put(allocator, local, "independent_lexical");
    var generator = Codegen.initWithOptions(allocator, &parser.ast, .{ .linking_metadata = &metadata, .semantic_symbols = analyzer.symbols.items });
    try std.testing.expectEqualStrings("chosen_outer", generator.finalSymbolName(local).?);
    const output = try generator.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, output, "independent_lexical") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "read: chosen_outer") != null);
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or analyzer.symbol_ids.items[raw] != local) continue;
        try std.testing.expectEqual(@as(?u32, local), generator.sourceSymbolId(@fromBackingInt(@as(u32, @intCast(raw)))));
    }
    _ = metadata.renames.remove(variable);
    try std.testing.expectEqualStrings("read", generator.finalSymbolName(local).?);
}

test "native body-var FDI names follow the exact parameter until its AST copy owns initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function run(value=1){var value;return value}");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var variable: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, index| if (!symbol.parameter_copy.parameter_source.isNone()) {
        variable = @intCast(index);
    };
    const body = variable orelse return error.MissingNativeParameterCopy;
    const parameter = @backingInt(analyzer.symbols.items[body].parameter_copy.parameter_source);
    try std.testing.expect(body != parameter);
    var metadata: Metadata = .{
        .skip_nodes = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len),
        .renames = .empty,
        .final_exports = null,
        .symbol_ids = analyzer.symbol_ids.items,
        .allocator = allocator,
    };
    try metadata.renames.put(allocator, parameter, "parameter_name");
    try metadata.renames.put(allocator, body, "body_name");
    var generator = Codegen.initWithOptions(allocator, &parser.ast, .{ .linking_metadata = &metadata, .semantic_symbols = analyzer.symbols.items });
    try std.testing.expectEqualStrings("parameter_name", generator.finalSymbolName(body).?);
    try @import("../semantic/parameter_body_var.zig").markLowered(analyzer.symbols.items, @fromBackingInt(body), @fromBackingInt(parameter));
    try std.testing.expectEqualStrings("body_name", generator.finalSymbolName(body).?);
    try std.testing.expectEqualStrings("parameter_name", generator.finalSymbolName(parameter).?);
}
