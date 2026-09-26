const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

fn checkCaptureSymbols(source: []const u8, frame_tag: @import("../parser/ast.zig").Node.Tag) !void {
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

    var outer_scope: ?u32 = null;
    var arrow_scope: ?u32 = null;
    var source_owners = analyzer.scope_owner_map.iterator();
    while (source_owners.next()) |owner| {
        const tag = parser.ast.nodes.items[owner.key_ptr.*].tag;
        if (tag == frame_tag) outer_scope = owner.value_ptr.*;
        if (tag == .arrow_function_expression) arrow_scope = owner.value_ptr.*;
    }
    const enclosing = outer_scope orelse return error.TestUnexpectedResult;
    const extracted = arrow_scope orelse return error.TestUnexpectedResult;
    const old_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
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

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var this_count: usize = 0;
    var arguments_count: usize = 0;
    for (edited.symbols.items[old_symbols..], old_symbols..) |symbol, index| {
        const is_this = std.mem.startsWith(u8, symbol.synthetic_name, "_this");
        const is_arguments = std.mem.startsWith(u8, symbol.synthetic_name, "_arguments");
        if (!is_this and !is_arguments) continue;
        if (is_this) this_count += 1 else arguments_count += 1;
        try std.testing.expectEqual(enclosing, @intFromEnum(symbol.scope_id));
        const id: u32 = @intCast(index);
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var ref_count: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != index or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@intFromEnum(ref.node_index)));
            try std.testing.expectEqual(extracted, @intFromEnum(ref.scope_id));
            try std.testing.expect(ref.flags.read);
            ref_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), ref_count);
        try std.testing.expectEqual(@as(u32, 1), symbol.reference_count);
    }
    try std.testing.expectEqual(@as(usize, 1), this_count);
    try std.testing.expectEqual(@as(usize, 1), arguments_count);
}

test "#4819 lowered arrow lexical captures have distinct exact function symbols" {
    try checkCaptureSymbols(
        "function outer(){return ()=>this.x+arguments[0]} outer.call({x:2},3);",
        .function_declaration,
    );
    try checkCaptureSymbols(
        "class C{method(){return ()=>this.x+arguments[0]}} new C().method();",
        .method_definition,
    );
    try checkCaptureSymbols(
        "class C{method(value=(()=>this.x+arguments.length)()){return value}} new C().method();",
        .method_definition,
    );
}
