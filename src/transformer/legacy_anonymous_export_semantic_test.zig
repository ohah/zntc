const std = @import("std");
const ast = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const Options = @import("options.zig").TransformOptions;

const cases = [_][]const u8{
    "@dec export default class {method(){return 7;}}",
    "export default class {@dec method(){return 7;}}",
    "@dec export default class {@dec method(){return 7;}}",
    "export default class {constructor(@dec value:number=7){} method(){return 7;}}",
    "export default class {@dec static read(){return 1;} method(){return 7;}}",
    "export default class {@dec get value(){return 1;} method(){return 7;}}",
    "export default class {@dec value=1; method(){return 7;}}",
    "export default class {@dec [\"meth\"+\"od\"](){return 7;}}",
    "@dec @dec export default class {method(){return 7;}}",
    "const _Class=99; @dec export default class {method(){return 7;} other(){return _Class;}}",
};

fn expectDeclarationAnchor(editor: anytype, id: u32, binding: ast.NodeIndex) !void {
    var found = false;
    for (editor.references.items) |edge| {
        if (@backingInt(edge.symbol_id) != id or !edge.flags.declare) continue;
        try std.testing.expectEqual(binding, edge.declaration_node_index);
        found = true;
    }
    try std.testing.expect(found);
}

fn expectBeforeFinish(source: []const u8, named_inner: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    if (parser.errors.items.len != 0) std.debug.print("source={s} errors={any}\n", .{ source, parser.errors.items });
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    try analyzer.analyze();
    var export_node: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .export_default_declaration) export_node = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!export_node.isNone());
    const source_class = parser.ast.getNode(export_node).data.unary.operand;
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .experimental_decorators = true,
        .unsupported = Options.compat.fromESTarget(if (named_inner) .es2015 else .es2022),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();
    const output = try transformer.visitExportDefaultDeclaration(transformer.ast.getNode(export_node));
    const binding_raw = transformer.lowered_anonymous_class_export_bindings.get(@backingInt(source_class)).?;
    const binding: ast.NodeIndex = @fromBackingInt(@intCast(binding_raw));
    const id = transformer.getSymbolIdAt(binding).?;
    const reference_node = transformer.ast.getNode(output).data.unary.operand;
    const editor = &transformer.semantic_editor.?;
    const reference = (try editor.referenceForNode(reference_node)).?;
    try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
    try std.testing.expectEqual(id, transformer.getSymbolIdAt(reference_node).?);
    try std.testing.expectEqual(transformer.programScope(), reference.scope_id);
    try std.testing.expect(reference.flags.read and !reference.flags.write);
    try std.testing.expectEqual(transformer.programScope(), editor.symbols.items[id].scope_id);
    try std.testing.expect(id >= analyzer.symbols.items.len);
    try expectDeclarationAnchor(editor, id, binding);
    var reference_count: u32 = 0;
    var write_count: u32 = 0;
    for (editor.references.items) |edge| {
        if (@backingInt(edge.symbol_id) != id or edge.flags.declare) continue;
        reference_count += 1;
        if (edge.flags.write) write_count += 1;
    }
    try std.testing.expectEqual(reference_count, editor.symbols.items[id].reference_count);
    try std.testing.expectEqual(write_count, editor.symbols.items[id].write_count);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_let, editor.symbols.items[id].kind);
    var found_storage = false;
    for (transformer.pending_nodes.items) |statement| {
        const node = transformer.ast.getNode(statement);
        if (node.tag != .variable_declaration) continue;
        const e = node.data.extra;
        const start = transformer.ast.extra_data.items[e + 1];
        const len = transformer.ast.extra_data.items[e + 2];
        for (transformer.ast.extra_data.items[start .. start + len]) |raw| {
            const declarator = transformer.ast.getNode(@fromBackingInt(@intCast(raw)));
            const declared = transformer.ast.readExtraNode(declarator.data.extra, 0);
            if (declared != binding) continue;
            const value = transformer.ast.readExtraNode(declarator.data.extra, 2);
            try std.testing.expectEqual(ast.Node.Tag.class_expression, transformer.ast.getNode(value).tag);
            const inner_name = transformer.ast.readExtraNode(transformer.ast.getNode(value).data.extra, ast.ClassExtra.name);
            if (named_inner) {
                try std.testing.expect(!inner_name.isNone());
                const inner_id = transformer.getSymbolIdAt(inner_name).?;
                try std.testing.expect(inner_id != id);
                try expectDeclarationAnchor(editor, inner_id, inner_name);
                try std.testing.expectEqual(inner_id, transformer.class_self_symbol_map.get(@backingInt(source_class)).?);
                try std.testing.expectEqual(transformer.outputOwnedScope(value).?, editor.symbols.items[inner_id].scope_id);
            } else try std.testing.expect(inner_name.isNone());
            found_storage = true;
        }
    }
    try std.testing.expect(found_storage);
}

test "anonymous legacy default export owns its binding and read before finalization" {
    for (cases) |source| try expectBeforeFinish(source, false);
}

test "anonymous legacy default export preserves its existing generated inner identity" {
    try expectBeforeFinish("@dec export default class {static value=1;method(){return 7;}}", true);
}
