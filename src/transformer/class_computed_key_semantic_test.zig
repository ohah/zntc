const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

fn initForComputedKey(alloc: std.mem.Allocator, parser: *Parser, analyzer: *SemanticAnalyzer) !Transformer {
    var t = try Transformer.init(alloc, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es2015) });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    return t;
}

fn computedKeyWrite(ast: *const ast_mod.Ast, root: NodeIndex) !struct { node: NodeIndex, statement: u32 } {
    const list = ast.getNode(root).data.list;
    for (ast.extra_data.items[list.start .. list.start + list.len], 0..) |raw, stmt| {
        const node = ast.nodes.items[raw];
        if (node.tag != .expression_statement) continue;
        const expression = ast.getNode(node.data.unary.operand);
        if (expression.tag != .assignment_expression) continue;
        if (ast.getNode(expression.data.binary.left).tag != .identifier_reference and ast.getNode(expression.data.binary.left).tag != .assignment_target_identifier) continue;
        if (ast.getNode(expression.data.binary.right).tag != .string_literal) continue;
        const text = ast.getText(ast.getNode(expression.data.binary.right).span);
        if (std.mem.indexOf(u8, text, "constructor") != null)
            return .{ .node = expression.data.binary.left, .statement = @intCast(stmt) };
    }
    return error.ComputedKeyWriteMissing;
}

fn expectComputedKeyWriteBeforeFinalization(source: []const u8) !void {
    errdefer std.debug.print("source: {s}\n", .{source});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    var t = try initForComputedKey(alloc, &parser, &analyzer);
    try t.buildBlockRenameMap();
    try @import("parameter_environment.zig").collectClassInferredNames(&t);
    try @import("native_parameter_cells.zig").normalize(&t);
    const root = try t.visitNode(@fromBackingInt(@as(u32, @intCast(t.parser_node_count - 1))));
    const write = try computedKeyWrite(t.ast, root);
    try std.testing.expectEqual(ast_mod.Node.Tag.assignment_target_identifier, t.ast.getNode(write.node).tag);
    const row = (try t.semantic_editor.?.referenceForNode(write.node)) orelse return error.ComputedKeyWriteReferenceMissing;
    const id = t.getSymbolIdAt(write.node) orelse return error.ComputedKeyWriteSymbolMissing;
    try std.testing.expectEqual(id, @backingInt(row.symbol_id));
    try std.testing.expect(row.flags.write and !row.flags.read);
    try std.testing.expectEqual(@as(ScopeId, @fromBackingInt(0)), row.scope_id);
    try std.testing.expectEqual(@as(ScopeId, @fromBackingInt(0)), t.semantic_editor.?.symbols.items[id].scope_id);
    var class_scope: ScopeId = .none;
    for (t.ast.nodes.items[0..t.parser_node_count], 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = @fromBackingInt(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.SourceClassScopeMissing);
    }
    var read_count: usize = 0;
    for (t.semantic_editor.?.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != id or !reference.flags.read) continue;
        try std.testing.expectEqual(class_scope, reference.scope_id);
        try std.testing.expect(!reference.flags.write);
        read_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), read_count);
}

test "computed class key write uses its actual outer scope before finalization" {
    const sources = [_][]const u8{
        "class Box{value=7;['constructor'](){return 2}}",
        "class Box{value=7;get ['constructor'](){return 2}}",
        "class Box{value=7;set ['constructor'](value){}}",
        "class Box{value=7;static ['constructor'](){return 2}}",
        "class Box{value=7;async ['constructor'](){return 2}}",
        "class Box{value=7;*['constructor'](){yield 2}}",
        "class Box{value=7;async *['constructor'](){yield 2}}",
        "const outside=7;class Box{value=outside;['constructor'](value=2){return value}}",
        "class Box{value=7;['constructor'](...values){return values.length}}",
        "class Box{static value=7;other=8;['constructor'](){return 2}}",
    };
    for (sources) |source| try expectComputedKeyWriteBeforeFinalization(source);
}

test "computed class key write contributes its actual statement writer edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, "const outside=7;class Box{value=outside;['constructor'](){return 2}}const box=new Box();console.log(box.value,box.constructor());");
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    var t = try initForComputedKey(alloc, &parser, &analyzer);
    const root = try t.transform();
    const write = try computedKeyWrite(t.ast, root);
    const edited = (try t.finishSemanticEdit()).?;
    const id = edited.symbol_ids[@backingInt(write.node)] orelse return error.ComputedKeyWriteSymbolMissing;
    // The bundler reindexes statement ordinals after the transformer. Supply
    // that known physical index without changing the producer's ScopeId.
    const references = try alloc.dupe(@import("../semantic/symbol.zig").Reference, edited.references);
    for (references) |*reference| if (reference.node_index == write.node) {
        reference.stmt_idx = write.statement;
        reference.scope_stmt_idx = write.statement;
    };
    const infos = (try @import("../bundler/stmt_info.zig").buildFromSemantic(alloc, t.ast, edited.symbols.items, edited.scopes, references, &analyzer.unresolved_references, false, false)) orelse return error.ComputedKeyStatementInfoMissing;
    try std.testing.expect(std.mem.indexOfScalar(u32, infos.writerStmts(id), write.statement) != null);
    const ast_infos = (try @import("../bundler/stmt_info.zig").build(alloc, t.ast, edited.symbols.items, edited.scopes, edited.symbol_ids, &analyzer.unresolved_references, false, false)) orelse return error.ComputedKeyAstStatementInfoMissing;
    try std.testing.expect(std.mem.indexOfScalar(u32, ast_infos.writerStmts(id), write.statement) != null);
}

test "computed class key read has its consumer scope at creation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, "class Box{['constructor']=7}");
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    var class_scope: ScopeId = .none;
    var key_value: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = @fromBackingInt(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.SourceClassScopeMissing);
        if (node.tag == .string_literal) key_value = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!class_scope.isNone() and !key_value.isNone());
    var t = try initForComputedKey(alloc, &parser, &analyzer);
    t.current_scope = class_scope;
    const capture = try @import("transformer/class_decorator.zig").captureMovedFieldComputedKey(&t, key_value, t.ast.getNode(key_value).span);
    const read = (try t.semantic_editor.?.referenceForNode(capture.read)) orelse return error.ComputedKeyReadReferenceMissing;
    try std.testing.expectEqual(class_scope, read.scope_id);
    try std.testing.expect(read.flags.read and !read.flags.write);
    try std.testing.expectEqual(@backingInt(capture.capture.symbol_id.?), t.getSymbolIdAt(capture.read).?);
    const target = t.ast.getNode(capture.capture.paren_assign).data.binary.left;
    const write = (try t.semantic_editor.?.referenceForNode(target)) orelse return error.ComputedKeyWriteReferenceMissing;
    try std.testing.expectEqual(t.outputScopeParent(class_scope), write.scope_id);
    try std.testing.expectEqual(read.symbol_id, write.symbol_id);
    try std.testing.expect(write.flags.write and !write.flags.read);
}
