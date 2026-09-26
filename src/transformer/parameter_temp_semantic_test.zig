const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ESTarget = @import("compat.zig").ESTarget;

fn checkParameterTempScope(source: []const u8, target: ESTarget) !void {
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

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        const node = parser.ast.nodes.items[owner.key_ptr.*];
        if (node.tag != .method_definition and node.tag != .function_declaration) continue;
        if (parser.ast.functionParamsList(node).len == 0) continue;
        try std.testing.expect(function_scope == null);
        function_scope = owner.value_ptr.*;
    }
    const expected_scope = function_scope orelse return error.TestUnexpectedResult;
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(target),
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

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var temp_count: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind != .variable_var or !std.mem.eql(u8, symbol.synthetic_name, "_a")) continue;
        temp_count += 1;
        try std.testing.expectEqual(expected_scope, @intFromEnum(symbol.scope_id));
        try std.testing.expectEqual(@as(u32, @intCast(symbol_index)), edited.scope_maps[expected_scope].get("_a").?);

        var bindings: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index))) bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);

        var refs: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != symbol_index or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@intFromEnum(ref.node_index)));
            try std.testing.expectEqual(expected_scope, @intFromEnum(ref.scope_id));
            try std.testing.expect(ref.flags.read or ref.flags.write);
            refs += 1;
        }
        try std.testing.expect(refs > 0);
        try std.testing.expectEqual(@as(u32, @intCast(refs)), symbol.reference_count);
    }
    try std.testing.expectEqual(@as(usize, 1), temp_count);
}

test "#4819 parameter optional-chain temp retains exact source function scope" {
    const fixtures = [_][]const u8{
        "function get(){return {value:5}} class C{constructor(value=get()?.value){this.value=value}} new C();",
        "function get(){return {value:5}} class C{method(value=get()?.value){return value}} new C().method();",
        "function get(){return {value:5}} class C{set value(input=get()?.value){this.saved=input}} new C().value=1;",
        "function get(){return {value:5}} class C{async method(value=get()?.value){return value}} new C().method();",
        "function get(){return {value:5}} class C{*method(value=get()?.value){yield value}} new C().method().next();",
        "function get(){return {value:5}} class C{async *method(value=get()?.value){yield value}} new C().method().next();",
        "function get(){return {value:5}} function* run(value=get()?.value){yield value} run().next();",
        "function get(){return {value:5}} async function run(value=get()?.value){return value} run();",
        "function get(){return {value:5}} async function* run(value=get()?.value){yield value} run().next();",
        "function get(){return {value:5}} async function* run(value=get()?.value){for await(const item of [1]) yield value+item} run().next();",
    };
    for (fixtures) |source| try checkParameterTempScope(source, .es5);
    try checkParameterTempScope(
        "function get(){return {value:5}} async function run(value=get()?.value){return value} run();",
        .es2016,
    );
}
