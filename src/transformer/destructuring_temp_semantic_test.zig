const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_walk = @import("../parser/ast_walk.zig");

test "#4819 ES5 destructuring temps keep exact IDs in hoisted function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function f() { const _a = 99; { const { x } = { x: 1 }; const {} = {}; console.log(x, _a); } }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration)
            function_scope = entry.value_ptr.*;
    }
    const expected_scope = function_scope orelse return error.MissingFunctionScope;
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
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
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);

    var temp_count: usize = 0;
    var unused_count: usize = 0;
    var used_count: usize = 0;
    var temps = transformer.destructuring_temp_symbol_ids.iterator();
    while (temps.next()) |entry| {
        const id = entry.value_ptr.*;
        try std.testing.expect(id >= original_symbol_count and id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        try std.testing.expectEqual(expected_scope, @intFromEnum(symbol.scope_id));
        try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, "_a"));
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[expected_scope].get(symbol.synthetic_name));
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var ref_count: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != id or ref.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @intFromEnum(ref.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            try std.testing.expect(ref.flags.read or ref.flags.write);
            ref_count += 1;
        }
        try std.testing.expectEqual(@as(usize, symbol.reference_count + symbol.write_count), ref_count);
        if (ref_count == 0) unused_count += 1 else used_count += 1;
        temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), temp_count);
    try std.testing.expectEqual(@as(usize, 1), unused_count);
    try std.testing.expectEqual(@as(usize, 1), used_count);
}
