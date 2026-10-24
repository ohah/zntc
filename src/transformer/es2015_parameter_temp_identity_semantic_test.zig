const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_walk = @import("../parser/ast_walk.zig");

fn sameSpan(a: anytype, b: anytype) bool {
    return a.start == b.start and a.end == b.end;
}

fn checkParameterAliasIdentity(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = false;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const original_symbol_count = analyzer.symbols.items.len;

    var target_node: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        if (target_node != null) return error.MultipleTopLevelFunctionDeclarations;
        target_node = @intCast(raw);
    }
    const function_raw = target_node orelse return error.MissingTargetFunction;
    const owner_raw = analyzer.scope_owner_map.get(function_raw) orelse return error.MissingTargetFunctionScope;
    const owner: ScopeId = @fromBackingInt(@intCast(owner_raw));
    const target_span = parser.ast.nodes.items[function_raw].span;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;

    const output_root = try transformer.transform();
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;

    var alias_id: ?u32 = null;
    for (editor.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, raw| {
        if (symbol.kind != .parameter or symbol.scope_id != owner or !sameSpan(symbol.declaration_span, target_span)) continue;
        if (!std.mem.startsWith(u8, symbol.synthetic_name, "_")) continue;
        if (alias_id != null) return error.MultipleGeneratedParameterAliases;
        alias_id = @intCast(raw);
    }
    const id = alias_id orelse return error.MissingGeneratedParameterAlias;
    const alias = editor.symbols.items[id];
    try std.testing.expectEqual(SymbolKind.parameter, alias.kind);
    try std.testing.expectEqual(owner, alias.scope_id);
    try std.testing.expect(alias.synthetic_kind == .standalone_temp_binding);

    const name_span = alias.name;
    try std.testing.expect(!transformer.pending_temp_ref_chains.contains(transformer.currentPendingTempRefKey(name_span)));

    var read_count: usize = 0;
    var write_count: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
        try std.testing.expectEqual(owner, reference.scope_id);
        try std.testing.expect(editor.symbolVisibleFrom(reference.symbol_id, reference.scope_id));
        const node = transformer.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference) return error.ParameterAliasReadIsNotAnIdentifier;
        try std.testing.expect(sameSpan(node.data.string_ref, alias.name));
        if (reference.flags.read) read_count += 1;
        if (reference.flags.write) write_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), read_count);
    try std.testing.expectEqual(@as(usize, 0), write_count);

    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, output_root);
    defer allocator.free(reachable);
    var binding_count: usize = 0;
    var reference_count: usize = 0;
    for (reachable) |raw| {
        if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != id) continue;
        const node = transformer.ast.nodes.items[raw];
        if (node.tag == .binding_identifier) binding_count += 1;
        if (node.tag == .identifier_reference) reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);
    try std.testing.expectEqual(@as(usize, 1), reference_count);
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(reference.node_index)) != null);
        try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(reference.node_index)]);
    }
    _ = root;
}

test "#4819 simple default-lowered parameter aliases retain producer identity" {
    const cases = [_][]const u8{
        "function target(value, fallback = 1) { return [value, fallback, arguments.length]; }",
        "const _a = 99; function target(value, fallback = 1) { return [value, fallback, arguments.length, _a]; }",
        "function target(value, fallback = 1) { return () => [value, fallback, arguments.length]; }",
        "function target(value, fallback = 1) { { let value = 8; if (value) return [fallback, arguments.length]; } return [value, arguments.length]; }",
        "let calls = 0; function target(value, fallback = (calls++, 4)) { return [value, fallback, calls, arguments.length]; }",
        "async function target(value, fallback = 1) { await Promise.resolve(); return [value, fallback, arguments.length]; }",
        "function* target(value, fallback = 1) { yield value; yield fallback; yield arguments.length; }",
        "function target(value, fallback = 1, ...tail) { return [value, fallback, tail.length, arguments.length]; }",
        "const _b = 7; function target(value, fallback = 1) { const record = { [fallback]: value, args: arguments.length }; return [record[fallback], record.args, _b]; }",
        "function target(value, fallback = 1) { try { throw fallback; } catch (_a) { if (_a) return [value, arguments.length]; } return [fallback, arguments.length]; }",
    };
    for (cases) |source| try checkParameterAliasIdentity(source);
}
