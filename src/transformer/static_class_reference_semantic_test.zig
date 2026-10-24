const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

fn checkStaticClassReferenceProducer(source: []const u8, static_context: bool, lower_class: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var class_node: ast_mod.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .class_declaration) {
            class_node = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
            break;
        }
    }
    try std.testing.expect(!class_node.isNone());
    const class_extra = parser.ast.getNode(class_node).data.extra;
    const name: ast_mod.NodeIndex = @fromBackingInt(@intCast(parser.ast.extra_data.items[class_extra + ast_mod.ClassExtra.name]));
    const declaration_id = analyzer.symbol_ids.items[@backingInt(name)] orelse return error.MissingClassDeclaration;
    const class_self_id = analyzer.class_self_symbol_map.get(@backingInt(class_node)) orelse return error.MissingClassSelf;
    try std.testing.expect(declaration_id != class_self_id);
    const class_scope = analyzer.symbols.items[class_self_id].scope_id;
    const name_span = parser.ast.getNode(name).data.string_ref;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(if (lower_class) .es5 else .es2015),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.current_class_name_node = name;
    transformer.current_class_self_symbol_id = class_self_id;
    transformer.current_scope = class_scope;
    transformer.static_block_class_name = if (static_context) name_span else null;

    // The producer's declaration handle remains authoritative even when a
    // spelling lookup cannot rediscover that declaration. No final AST walk
    // or lexical-reference repair has run at this point.
    const declaration_scope = analyzer.symbols.items[declaration_id].scope_id;
    var decode_buf: [256]u8 = undefined;
    const raw_name = parser.ast.getText(name_span);
    const decoded_name = Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buf) orelse raw_name;
    _ = analyzer.scope_maps.items[declaration_scope.toIndex()].remove(raw_name);
    _ = analyzer.scope_maps.items[declaration_scope.toIndex()].remove(decoded_name);

    const reference = try transformer.makeCurrentClassRefAtScope(name_span, class_scope);
    const expected_id = if (static_context and !lower_class) declaration_id else class_self_id;
    try std.testing.expectEqual(@as(?u32, expected_id), transformer.getSymbolIdAt(reference));
    try std.testing.expectEqualStrings(raw_name, transformer.ast.getText(transformer.ast.getNode(reference).data.string_ref));
    try std.testing.expectEqual(if (static_context) @as(?u32, expected_id) else null, transformer.exact_output_ref_symbol_ids.get(@backingInt(reference)));
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const recorded = (try editor.referenceForNode(reference)) orelse return error.MissingProducerReference;
    try std.testing.expectEqual(expected_id, @backingInt(recorded.symbol_id));
    try std.testing.expectEqual(class_scope, recorded.scope_id);
    try std.testing.expect(recorded.flags.read);
    try std.testing.expect(!recorded.flags.write);
}

test "#4819 static class reference producer reads the exact declaration at creation" {
    const cases = [_][]const u8{
        "class Box { static value = 7; static read = () => this.value; }",
        "function outer() { class Box { static read = () => this; } return Box; }",
        "const _a = 4; class Box { static read = () => this === Box; }",
        "class \\u0042ox { static read = () => this; }",
        "const Base = Object; class Box extends Base { static read = () => this; }",
        "class Box { static { this.value = 7; } }",
        "class Box { static #value = this; static read() { return this.#value; } }",
        "class Box { static get value() { return 7; } static read = () => this.value; }",
        "function outer(value) { class Box { static read = () => () => this === value; } return Box; }",
        "const name = 'read'; class Box { static [name] = () => this; }",
    };
    for (cases) |source| try checkStaticClassReferenceProducer(source, true, false);
}

test "#4819 static class reference producer leaves ordinary class-self reads unchanged" {
    try checkStaticClassReferenceProducer("class Box { read() { return Box; } }", false, false);
}

test "#4819 static class reference producer keeps the lowered implementation identity" {
    try checkStaticClassReferenceProducer("class Box { static read = () => this; }", true, true);
}
