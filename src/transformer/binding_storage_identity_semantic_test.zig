const std = @import("std");
const ast = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const edit = @import("transformer/semantic_edit.zig");
const es = @import("es_helpers.zig");

const sources = [_][]const u8{
    "var value=1;function f(){}",
    "let value=1;const f=()=>{};",
    "const value=1;const f=function(){};",
    "let value=1;async function f(){}",
    "const value=1;function* f(){}",
    "var value=1;const object={method(){}};",
    "let value=1;const object={get read(){}};",
    "const value=1;class Box{method(){}}",
    "var value=1;class Box{static method(){}}",
    "var value=1;function f(arg=0){}",
};

const Mode = enum { valid, duplicated_id, colliding_placement };

fn runStorageCase(source: []const u8, mode: Mode) !void {
    const broken = mode == .duplicated_id;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    try analyzer.analyze();
    const program = parser.ast.getNode(root).data.list;
    const outer_declaration = parser.ast.getNode(@fromBackingInt(@intCast(parser.ast.extra_data.items[program.start])));
    const outer_declarator = parser.ast.getNode(@fromBackingInt(@intCast(parser.ast.extra_data.items[parser.ast.extra_data.items[outer_declaration.data.extra + 1]])));
    const outer_binding = parser.ast.readExtraNode(outer_declarator.data.extra, 0);
    const original_value = parser.ast.readExtraNode(outer_declarator.data.extra, 2);
    const outer_id = analyzer.symbol_ids.items[@backingInt(outer_binding)].?;
    const source_name_span = parser.ast.getNode(outer_binding).data.string_ref;
    var owner: ast.NodeIndex = .none;
    var body: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        const body_offset: u32 = switch (node.tag) {
            .function_declaration, .function_expression, .function => ast.FunctionExtra.body,
            .arrow_function_expression => ast.ArrowExtra.body,
            .method_definition => ast.MethodExtra.body,
            else => continue,
        };
        const candidate = parser.ast.readExtraNode(node.data.extra, body_offset);
        if (!candidate.isNone() and parser.ast.getNode(candidate).tag == .block_statement and
            parser.ast.getNode(candidate).data.list.len == 0)
        {
            owner = @fromBackingInt(@intCast(raw));
            body = candidate;
            break;
        }
    }
    try std.testing.expect(!owner.isNone() and !body.isNone());
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const scope = transformer.outputOwnedScope(owner).?;
    transformer.current_scope = scope;
    const name_span = try transformer.ast.addString(parser.ast.getText(source_name_span));
    const binding = if (broken)
        try transformer.makeUserBinding(name_span, outer_binding)
    else
        try es.makeExactSyntheticBindingFromSpan(&transformer, name_span);
    const inner_id = if (broken) outer_id else @backingInt((try transformer.declareSyntheticInScope(binding, source_name_span, .variable_var, scope)).?);
    try std.testing.expectEqual(inner_id, transformer.getSymbolIdAt(binding).?);
    if (!broken) {
        try std.testing.expect(inner_id != outer_id);
        try std.testing.expectEqual(scope, transformer.semantic_editor.?.symbols.items[inner_id].scope_id);
    }
    const reference = try es.makeExactSyntheticRefFromSpan(&transformer, name_span);
    try transformer.addSyntheticRefInScope(reference, @fromBackingInt(inner_id), scope, .{ .read = true });
    const value = try transformer.ast.addNode(transformer.ast.getNode(original_value));
    const declaration = try es.makeVarDeclaration(&transformer, &.{try es.makeDeclarator(&transformer, binding, value, name_span)}, .@"var", name_span);
    const read = try transformer.ast.addNode(.{ .tag = .return_statement, .span = name_span, .data = .{ .unary = .{ .operand = reference, .flags = 0 } } });
    if (mode == .colliding_placement) {
        transformer.ast.nodes.items[@backingInt(body)].data.list = try transformer.ast.addNodeList(&.{read});
        const current = transformer.ast.getNode(root).data.list;
        var statements: std.ArrayList(ast.NodeIndex) = .empty;
        for (transformer.ast.extra_data.items[current.start .. current.start + current.len]) |raw|
            try statements.append(allocator, @fromBackingInt(@intCast(raw)));
        try statements.append(allocator, declaration);
        transformer.ast.nodes.items[@backingInt(root)].data.list = try transformer.ast.addNodeList(statements.items);
    } else transformer.ast.nodes.items[@backingInt(body)].data.list = try transformer.ast.addNodeList(&.{ declaration, read });
    const editor = &transformer.semantic_editor.?;
    const before_count = editor.symbols.items.len;
    const scope_count = editor.scopes.items.len;
    if (mode != .valid) {
        try std.testing.expectError(error.InvalidSymbol, edit.bindOutputScopesAndReferencesChecked(&transformer, root, transformer.programScope()));
    } else {
        try edit.bindOutputScopesAndReferencesChecked(&transformer, root, transformer.programScope());
    }
    try std.testing.expectEqual(before_count, editor.symbols.items.len);
    try std.testing.expectEqual(scope_count, editor.scopes.items.len);
    try std.testing.expectEqual(inner_id, transformer.getSymbolIdAt(binding).?);
    try std.testing.expectEqual(inner_id, transformer.getSymbolIdAt(reference).?);
    const edge = (try editor.referenceForNode(reference)).?;
    try std.testing.expectEqual(inner_id, @backingInt(edge.symbol_id));
    try std.testing.expectEqual(scope, edge.scope_id);
    if (mode == .valid) {
        var empty: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const report = try @import("symbol_coverage.zig").checkExact(allocator, transformer.ast, root, transformer.parser_node_count, transformer.symbol_ids.items, editor.symbols.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &.{}, &editor.helper_scope_map, &empty, &empty, &transformer.reference_origin_map);
        try std.testing.expect(report.isClean());
        var overrides: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        try overrides.put(allocator, outer_id, "outer_slot");
        try overrides.put(allocator, inner_id, "inner_slot");
        var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(allocator, transformer.ast, .{
            .semantic_symbol_ids = transformer.symbol_ids.items,
            .semantic_symbols = editor.symbols.items,
            .semantic_symbol_name_overrides = &overrides,
            .semantic_scope_maps = editor.scope_maps.items,
            .generated_iife_scope_owner_map = &editor.scope_owner_map,
        });
        const code = try codegen.generate(root);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, code, "outer_slot"));
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, code, "inner_slot"));
    }
}

fn runAllStorageCases(mode: Mode) !void {
    var failures: usize = 0;
    var executed: usize = 0;
    for (sources, 0..) |source, index| {
        if (mode == .colliding_placement and !std.mem.startsWith(u8, source, "var ")) continue;
        executed += 1;
        runStorageCase(source, mode) catch |err| {
            failures += 1;
            std.debug.print("storage protocol mode={s} case={d} source={s} failure={s}\n", .{ @tagName(mode), index, source, @errorName(err) });
        };
    }
    try std.testing.expectEqual(@as(usize, if (mode == .colliding_placement) 4 else 10), executed);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "storage identities are selected by the producer before finalization" {
    try runAllStorageCases(.valid);
}

test "storage identities are never invented to repair a duplicated producer ID" {
    try runAllStorageCases(.duplicated_id);
}

test "storage identities are not merged into same-spelled var storage" {
    try runAllStorageCases(.colliding_placement);
}

test "Annex B shape cannot legitimize a different producer binding identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "var value = 1; if (true) { function inner() {} }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    try analyzer.analyze();

    const program = parser.ast.getNode(root).data.list;
    const declaration = parser.ast.getNode(@fromBackingInt(@intCast(parser.ast.extra_data.items[program.start])));
    const declarator = parser.ast.getNode(@fromBackingInt(@intCast(parser.ast.extra_data.items[parser.ast.extra_data.items[declaration.data.extra + 1]])));
    const outer_binding = parser.ast.readExtraNode(declarator.data.extra, 0);
    const outer_id = analyzer.symbol_ids.items[@backingInt(outer_binding)].?;
    var function_name: ast.NodeIndex = .none;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .function_declaration) continue;
        function_name = parser.ast.readExtraNode(node.data.extra, ast.FunctionExtra.name);
        if (!function_name.isNone()) break;
    }
    try std.testing.expect(!function_name.isNone());

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    // Simulate a producer assigning the unrelated outer `value` identity to
    // the block function. Final placement must reject it before Annex B can
    // treat scope and function-declaration shape as sufficient evidence.
    transformer.symbol_ids.items[@backingInt(function_name)] = outer_id;
    try std.testing.expectError(
        error.InvalidSymbol,
        edit.bindOutputScopesAndReferencesChecked(&transformer, root, transformer.programScope()),
    );
}

test "Annex B accepts a same-name alias with a long escaped spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const name_len = 60;
    const plain_name = try allocator.alloc(u8, name_len);
    @memset(plain_name, 'a');
    var escaped_name: std.ArrayList(u8) = .empty;
    defer escaped_name.deinit(allocator);
    for (0..name_len) |_| try escaped_name.appendSlice(allocator, "\\u0061");
    try std.testing.expect(escaped_name.items.len > 256);

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "var ");
    try source.appendSlice(allocator, plain_name);
    try source.appendSlice(allocator, "=1;if(true){function ");
    try source.appendSlice(allocator, escaped_name.items);
    try source.appendSlice(allocator, "(){}}");

    var scanner = try Scanner.init(allocator, source.items);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    try analyzer.analyze();

    const program = parser.ast.getNode(root).data.list;
    const declaration = parser.ast.getNode(@fromBackingInt(@intCast(parser.ast.extra_data.items[program.start])));
    const declarator = parser.ast.getNode(@fromBackingInt(@intCast(parser.ast.extra_data.items[declaration.data.extra + 1])));
    const outer_binding = parser.ast.readExtraNode(declarator.data.extra, 0);
    const outer_id = analyzer.symbol_ids.items[@backingInt(outer_binding)].?;
    var function_name: ast.NodeIndex = .none;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .function_declaration) continue;
        function_name = parser.ast.readExtraNode(node.data.extra, ast.FunctionExtra.name);
        if (!function_name.isNone()) break;
    }
    try std.testing.expect(!function_name.isNone());
    try std.testing.expectEqual(outer_id, analyzer.symbol_ids.items[@backingInt(function_name)].?);

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    try edit.bindOutputScopesAndReferencesChecked(&transformer, root, transformer.programScope());
}
