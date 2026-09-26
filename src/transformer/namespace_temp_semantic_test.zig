const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_walk = @import("../parser/ast_walk.zig");
const Reference = @import("../semantic/symbol.zig").Reference;

test "#4819 namespace destructuring temp has one IIFE binding and exact read reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "namespace N { export const { value } = { value: 1 }; } namespace N { export const next = value + 2; }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_ts = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var first_namespace_scope: ?u32 = null;
    var scope_it = analyzer.scope_owner_map.iterator();
    while (scope_it.next()) |entry| {
        const owner = parser.ast.nodes.items[entry.key_ptr.*];
        if (owner.tag != .ts_module_declaration or owner.span.start != 0) continue;
        first_namespace_scope = entry.value_ptr.*;
    }
    const expected_scope = first_namespace_scope orelse return error.MissingNamespaceScope;
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());

    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);
    var temp_count: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, si| {
        if (!std.mem.eql(u8, symbol.synthetic_name, "_a")) continue;
        temp_count += 1;
        try std.testing.expectEqual(expected_scope, @intFromEnum(symbol.scope_id));
        try std.testing.expectEqual(@as(?usize, si), edited.scope_maps[expected_scope].get("_a"));
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(si))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var read_count: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != si or ref.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @intFromEnum(ref.node_index)) != null);
            try std.testing.expectEqual(expected_scope, @intFromEnum(ref.scope_id));
            try std.testing.expect(ref.flags.read and !ref.flags.write);
            try std.testing.expectEqual(Reference.NO_STMT, ref.stmt_idx);
            try std.testing.expectEqual(@as(?u32, @intCast(si)), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            read_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), read_count);
        try std.testing.expectEqual(@as(u32, 1), symbol.reference_count);
        try std.testing.expectEqual(@as(u32, 0), symbol.write_count);
    }
    try std.testing.expectEqual(@as(usize, 1), temp_count);
}

test "#4819 empty namespace destructuring temps retain SymbolId and IIFE scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "namespace N { export const {} = { ignored: 1 }; export const [] = []; }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_ts = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var namespace_scope: ?u32 = null;
    var scope_it = analyzer.scope_owner_map.iterator();
    while (scope_it.next()) |entry| {
        const owner = parser.ast.nodes.items[entry.key_ptr.*];
        if (owner.tag == .ts_module_declaration and owner.span.start == 0) namespace_scope = entry.value_ptr.*;
    }
    const expected_scope = namespace_scope orelse return error.MissingNamespaceScope;

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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());

    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);
    var temp_count: usize = 0;
    for (reachable) |raw| {
        if (!transformer.destructuring_temp_bindings.contains(raw)) continue;
        try std.testing.expect(transformer.ast.nodes.items[raw].tag == .binding_identifier);
        const sid = if (raw < edited.symbol_ids.len) edited.symbol_ids[raw] orelse return error.MissingNamespaceTempSymbol else return error.MissingNamespaceTempSymbol;
        const symbol = edited.symbols.items[sid];
        try std.testing.expectEqual(expected_scope, @intFromEnum(symbol.scope_id));
        try std.testing.expectEqual(@as(?usize, sid), edited.scope_maps[expected_scope].get(symbol.synthetic_name));
        try std.testing.expectEqual(@as(u32, 0), symbol.reference_count);
        try std.testing.expectEqual(@as(u32, 0), symbol.write_count);
        for (edited.references) |ref| {
            if (!ref.flags.declare) try std.testing.expect(@intFromEnum(ref.symbol_id) != sid);
        }
        temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), temp_count);
}
