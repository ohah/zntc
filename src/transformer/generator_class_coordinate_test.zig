const std = @import("std");
const ast = @import("../parser/ast.zig");
const T = @import("transformer.zig").Transformer;
const source = "function* run(){function sibling(){class Cell{}return Cell.name}for(var index=0;index<2;index++){yield 0;sibling()}}";

fn profile() @import("compat.zig").UnsupportedFeatures {
    var unsupported = @import("compat.zig").fromESTarget(.es2015);
    unsupported.generator = true;
    return unsupported;
}

test "generator class statement owner follows copied nested class identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const input = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    var class_ids = analyzer.class_self_symbol_map.valueIterator();
    const inner = (class_ids.next() orelse return error.MissingClassIdentity).*;
    const class_scope = analyzer.symbols.items[inner].scope_id;
    var t = try T.init(a, &parser.ast, .{ .unsupported = profile() });
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
    try t.buildBlockRenameMap();
    const output = try t.visitNode(input);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    try @import("es2015_generator.zig").ES2015Generator(T).projectFunctionStorageCoordinates(&t, output);
    const contexts = try @import("../bundler/statement_owner_projection.zig").collect(a, t.ast, output);
    var expected: ?@import("../bundler/statement_owner_projection.zig").Context = null;
    var owners: usize = 0;
    for (t.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const context = contexts[raw] orelse continue;
        const owner = t.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(raw)))) orelse continue;
        if (owner != class_scope) continue;
        owners += 1;
        expected = context;
    }
    try std.testing.expectEqual(@as(usize, 1), owners);
    const context = expected orelse return error.MissingCurrentClassOwner;
    try std.testing.expectEqual(class_scope, t.semantic_editor.?.symbols.items[inner].scope_id);
    var rows: usize = 0;
    for (t.semantic_editor.?.references.items) |reference| {
        if (!reference.flags.declare or @backingInt(reference.symbol_id) != inner) continue;
        rows += 1;
        try std.testing.expect(reference.declaration_node_index.isNone());
        try std.testing.expectEqual(context.stmt_idx, reference.stmt_idx);
        try std.testing.expectEqual(context.scope_stmt_idx, reference.scope_stmt_idx);
    }
    try std.testing.expectEqual(@as(usize, 1), rows);
}

test "generator class statement owner public output keeps sibling runtime values" {
    const sources = [_][]const u8{
        "function* run(){const values=[];function sibling(){class Cell{}return Cell.name}for(var index=0;index<2;index++){yield 0;values.push(sibling())}return values}var it=run(),s;do{s=it.next()}while(!s.done);console.log(JSON.stringify(s.value));",
        "async function run(){const values=[];function sibling(){class Cell{}return Cell.name}for(var index=0;index<2;index++){await 0;values.push(sibling())}return values}run().then(v=>console.log(JSON.stringify(v)));",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (sources) |text| for ([_]bool{ false, true }) |minify| {
        const output = try @import("../transpile.zig").transpile(a, text, "nested-class.js", .{ .unsupported = profile(), .minify_identifiers = minify, .minify_syntax = minify, .keep_names = true });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", text }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        try std.testing.expectEqualStrings(native.stderr, actual.stderr);
    };
}
