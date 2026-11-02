const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const parameter_environment = @import("parameter_environment.zig");

test "parameter environment renames recover source owner after poisoned scope-map row" {
    const Poison = enum { foreign_scope, same_scope_wrong_name, out_of_range };
    const source = "const x = 9; function f(a = x) { var x = 1, y = 2; return a; }";
    const poisons = [_]Poison{ .foreign_scope, .same_scope_wrong_name, .out_of_range };

    for (poisons) |poison| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        _ = try parser.parse();
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

        var function_node: ast_mod.NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            if (name.isNone() or !std.mem.eql(u8, parser.ast.identifierNameText(parser.ast.getNode(name)), "f")) continue;
            function_node = @fromBackingInt(@intCast(raw));
            break;
        }
        try std.testing.expect(!function_node.isNone());
        const function_scope = analyzer.scope_owner_map.get(@backingInt(function_node)) orelse return error.MissingFunctionScope;
        const body_map = &analyzer.scope_maps.items[function_scope];
        const body_x = body_map.get("x") orelse return error.MissingBodyX;
        const body_y = body_map.get("y") orelse return error.MissingBodyY;
        const outer_x = analyzer.scope_maps.items[0].get("x") orelse return error.MissingOuterX;
        try std.testing.expect(body_x != outer_x);

        const replacement = switch (poison) {
            .foreign_scope => outer_x,
            .same_scope_wrong_name => body_y,
            .out_of_range => analyzer.symbols.items.len,
        };
        body_map.getPtr("x").?.* = replacement;

        var transformer = try Transformer.init(allocator, &parser.ast, .{
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;

        var renames = try parameter_environment.collectRenames(&transformer);
        defer renames.deinit(allocator);
        try std.testing.expect(renames.contains(@intCast(body_x)));
        try std.testing.expect(!renames.contains(@intCast(outer_x)));
        try std.testing.expect(!renames.contains(@intCast(body_y)));
    }
}

test "parameter environment field-capture rename uses anchored constructor binding" {
    const source = "const token = 9; class Box { value = token; constructor(token) { return token; } }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    const outer_id = analyzer.scope_maps.items[0].get("token") orelse return error.MissingOuterToken;
    var parameter_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, parser.ast.identifierNameText(node), "token")) continue;
        const id = analyzer.symbol_ids.items[raw] orelse continue;
        if (analyzer.symbols.items[id].kind == .parameter) parameter_id = id;
    }
    const constructor_parameter = parameter_id orelse return error.MissingConstructorParameter;
    const parameter_scope = analyzer.symbols.items[constructor_parameter].scope_id;
    try std.testing.expect(!parameter_scope.isNone());
    analyzer.scope_maps.items[parameter_scope.toIndex()].getPtr("token").?.* = outer_id;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var renames = try parameter_environment.collectFieldCaptureRenames(&transformer);
    defer renames.deinit(allocator);
    try std.testing.expect(renames.contains(constructor_parameter));
    try std.testing.expect(!renames.contains(@intCast(outer_id)));
}

test "parameter dynamic-lookup rename includes every anchored body binding" {
    const source = "function f({ ...rest }, a = eval('body')) { var body = 1, decoy = 2; return body + decoy; }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_node: ast_mod.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone() or !std.mem.eql(u8, parser.ast.identifierNameText(parser.ast.getNode(name)), "f")) continue;
        function_node = @fromBackingInt(@intCast(raw));
        break;
    }
    try std.testing.expect(!function_node.isNone());
    const function_scope = analyzer.scope_owner_map.get(@backingInt(function_node)) orelse return error.MissingFunctionScope;
    const body_map = &analyzer.scope_maps.items[function_scope];
    const body_id = body_map.get("body") orelse return error.MissingBodyBinding;
    const decoy_id = body_map.get("decoy") orelse return error.MissingDecoyBinding;
    try std.testing.expect(body_id != decoy_id);
    body_map.getPtr("body").?.* = decoy_id;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2016),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    try std.testing.expect(!transformer.options.unsupported.default_params);
    try std.testing.expect(transformer.options.unsupported.object_spread);
    const params_node = parser.ast.readExtraNode(parser.ast.getNode(function_node).data.extra, ast_mod.FunctionExtra.params);
    const parameter_scope = analyzer.scope_owner_map.get(@backingInt(params_node)) orelse return error.MissingParameterScope;
    try std.testing.expect(analyzer.scopes.items[parameter_scope].subtree_has_direct_eval);
    try std.testing.expect(!analyzer.scopes.items[function_scope].blocksMangling());

    var renames = try parameter_environment.collectRenames(&transformer);
    defer renames.deinit(allocator);
    try std.testing.expect(renames.contains(@intCast(body_id)));
    try std.testing.expect(renames.contains(@intCast(decoy_id)));
}

test "parameter field-capture rename accepts an escaped equal body-var name" {
    const source = "const outer = 9; class C { value = outer; constructor(outer = 0) { var \\u006futer = 2; } }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var parameter_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, parser.ast.getText(symbol.name), "outer")) {
            parameter_id = @intCast(raw);
            break;
        }
    }
    const id = parameter_id orelse return error.MissingParameterBinding;
    var body_var_id: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .variable_var and std.mem.eql(u8, parser.ast.getText(symbol.name), "\\u006futer")) {
            body_var_id = @intCast(raw);
            break;
        }
    }
    const body_var = body_var_id orelse return error.MissingEscapedBodyVar;
    var field_capture_renames = try parameter_environment.collectFieldCaptureRenames(&transformer);
    defer field_capture_renames.deinit(allocator);
    try std.testing.expect(field_capture_renames.contains(id));
    try std.testing.expect(field_capture_renames.contains(body_var));

    try transformer.buildBlockRenameMap();
    const renamed = transformer.block_rename_map.?.get(id) orelse return error.MissingParameterRename;
    try std.testing.expect(!std.mem.eql(u8, renamed, "outer"));
    const renamed_body_var = transformer.block_rename_map.?.get(body_var) orelse return error.MissingBodyVarRename;
    try std.testing.expect(!std.mem.eql(u8, renamed_body_var, "outer"));
}
