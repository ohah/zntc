const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_walk = @import("../parser/ast_walk.zig");
const Reference = @import("../semantic/symbol.zig").Reference;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const LinkingMetadata = @import("../bundler/linker.zig").LinkingMetadata;

test "#4819 namespace variable uses become member AST nodes with the exact IIFE parameter SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "namespace N { const _N = 0; export let x = 1; function bump() { x += x; return x; } function shadow(x) { return x; } export namespace Child { export const y = x; } }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_ts = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var namespace_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .ts_module_declaration or node.span.start != 0) continue;
        namespace_scope = analyzer.scope_owner_map.get(@intCast(raw));
        break;
    }
    const namespace_scope_id = namespace_scope orelse return error.MissingNamespaceScope;
    var parameter_sid: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.synthetic_kind == .namespace_iife_parameter and @intFromEnum(symbol.scope_id) == namespace_scope_id) {
            parameter_sid = @intCast(raw);
            break;
        }
    }
    const expected_parameter_sid = parameter_sid orelse return error.MissingNamespaceParameterSymbol;

    var exported_sid: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "x")) continue;
        const sid = analyzer.symbol_ids.items[raw] orelse continue;
        if (@intFromEnum(analyzer.symbols.items[sid].scope_id) == namespace_scope_id) {
            exported_sid = sid;
            break;
        }
    }
    const expected_exported_sid = exported_sid orelse return error.MissingExportedVariableSymbol;
    var shadow_sid: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "x")) continue;
        const sid = analyzer.symbol_ids.items[raw] orelse continue;
        if (sid != expected_exported_sid and analyzer.symbols.items[sid].kind == .parameter) {
            shadow_sid = sid;
            break;
        }
    }
    const expected_shadow_sid = shadow_sid orelse return error.MissingShadowParameterSymbol;
    try std.testing.expect(!std.mem.eql(u8, analyzer.symbols.items[expected_parameter_sid].synthetic_name, "_N"));

    var transformer = try Transformer.init(alloc, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);

    var member_count: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == expected_exported_sid) {
                return error.ExportedReferenceWasNotRemoved;
            }
        }
        if (node.tag != .static_member_expression) continue;
        const extra = node.data.extra;
        if (extra + 2 >= transformer.ast.extra_data.items.len) continue;
        const object_idx: u32 = transformer.ast.extra_data.items[extra];
        const property_idx: u32 = transformer.ast.extra_data.items[extra + 1];
        if (property_idx >= transformer.ast.nodes.items.len) continue;
        if (object_idx >= edited.symbol_ids.len or edited.symbol_ids[object_idx] != expected_parameter_sid) continue;
        const property = transformer.ast.nodes.items[property_idx];
        if (property.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(property.data.string_ref), "x")) continue;
        member_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), member_count);

    var shadow_reads: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or raw >= edited.symbol_ids.len or
            edited.symbol_ids[raw] != expected_shadow_sid) continue;
        shadow_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shadow_reads);

    var parameter_reads: usize = 0;
    for (edited.references) |reference| {
        if (reference.flags.declare or @intFromEnum(reference.symbol_id) != expected_parameter_sid) continue;
        const raw = @intFromEnum(reference.node_index);
        if (std.mem.indexOfScalar(u32, reachable, raw) == null) continue;
        try std.testing.expect(reference.flags.read and !reference.flags.write);
        try std.testing.expectEqual(@as(?u32, expected_parameter_sid), edited.symbol_ids[raw]);
        parameter_reads += 1;
    }
    try std.testing.expectEqual(member_count, parameter_reads);
    try std.testing.expectEqual(@as(u32, 0), edited.symbols.items[expected_exported_sid].reference_count);
    try std.testing.expectEqual(@as(u32, 0), edited.symbols.items[expected_exported_sid].write_count);
    try std.testing.expectEqual(@as(u32, @intCast(member_count)), edited.symbols.items[expected_parameter_sid].reference_count);
    try std.testing.expectEqual(@as(u32, 0), edited.symbols.items[expected_parameter_sid].write_count);

    var linking_metadata: LinkingMetadata = .{
        .skip_nodes = try std.DynamicBitSet.initEmpty(alloc, transformer.ast.nodes.items.len),
        .final_exports = null,
        .symbol_ids = edited.symbol_ids,
        .allocator = alloc,
    };
    defer linking_metadata.deinit();
    try linking_metadata.renames.put(alloc, expected_parameter_sid, "p");

    var codegen = Codegen.initWithOptions(alloc, transformer.ast, .{
        .minify_whitespace = true,
        .linking_metadata = &linking_metadata,
        .semantic_symbols = edited.symbols.items,
        .semantic_scope_maps = edited.scope_maps,
        .generated_iife_scope_owner_map = &edited.scope_owner_map,
    });
    const output = try codegen.generate(root);
    const expected_access = "p.x+=p.x;return p.x";
    try std.testing.expect(std.mem.indexOf(u8, output, expected_access) != null);
}

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
            var use_scope = ref.scope_id;
            var resolves_temp = false;
            while (!use_scope.isNone()) {
                if (@intFromEnum(use_scope) == expected_scope) {
                    resolves_temp = true;
                    break;
                }
                use_scope = edited.scopes[use_scope.toIndex()].parent;
            }
            try std.testing.expect(resolves_temp);
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
