const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const ast_mod = @import("../parser/ast.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const Reference = @import("../semantic/symbol.zig").Reference;

fn checkGeneratedTemps(source: []const u8, target: TransformOptions.compat.ESTarget, expected: usize, has_state: bool) !void {
    return checkGeneratedTempsWithBlock(source, target, expected, has_state, false);
}

fn checkGeneratedTempsWithBlock(source: []const u8, target: TransformOptions.compat.ESTarget, expected: usize, has_state: bool, expect_block_refs: bool) !void {
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
    const source_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(target),
        .emit_runtime_helper_imports = true,
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
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var found: usize = 0;
    for (edited.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind != .variable_var or symbol.synthetic_name.len < 2 or symbol.synthetic_name[0] != '_') continue;
        // The private receiver expression creates one write and two reads.
        if (symbol.reference_count != 3 or symbol.write_count != 1) continue;
        found += 1;
        try std.testing.expect(symbol.scope_id.toIndex() >= analyzer.scopes.items.len);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);
        var owner_count: usize = 0;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @intFromEnum(symbol.scope_id)) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, entry.key_ptr.*) != null);
            try std.testing.expectEqual(ast_mod.Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            owner_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), owner_count);
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var ref_count: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != symbol_index or ref.node_index.isNone()) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @intFromEnum(ref.node_index)) != null);
            if (expect_block_refs) {
                try std.testing.expect(ref.scope_id != symbol.scope_id);
                try std.testing.expectEqual(symbol.scope_id, edited.scopes[ref.scope_id.toIndex()].parent);
            } else {
                try std.testing.expectEqual(symbol.scope_id, ref.scope_id);
            }
            try std.testing.expectEqual(Reference.NO_STMT, ref.stmt_idx);
            try std.testing.expectEqual(Reference.NO_STMT, ref.scope_stmt_idx);
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            ref_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), ref_count);
        if (has_state) {
            var state_found = false;
            for (edited.symbols.items[source_symbol_count..]) |candidate| {
                if (candidate.kind == .parameter and std.mem.startsWith(u8, candidate.synthetic_name, "_state") and candidate.scope_id == symbol.scope_id)
                    state_found = true;
            }
            try std.testing.expect(state_found);
        }
    }
    try std.testing.expectEqual(expected, found);
}

test "#4819 callback local private receiver temp has exact binding and references" {
    const source = "class Box { static #method() { return 1; } static receiver() { return this; } static async run() { await Promise.resolve(); return this.receiver().#method(); } }";
    try checkGeneratedTemps(source, .es5, 1, true);
}

test "#4819 generator and async generator callback temps stay separate" {
    try checkGeneratedTemps("class Box { static #method() { return 1; } static receiver() { return this; } static *run() { yield this.receiver().#method(); } }", .es5, 1, true);
    try checkGeneratedTemps("class Box { static #method() { return 1; } static receiver() { return this; } static async *run() { yield await Promise.resolve(this.receiver().#method()); } }", .es5, 1, true);
}

test "#4819 native generator async body temp belongs to inner function" {
    const source = "class Box { static #method() { return 1; } static receiver() { return this; } static async run() { await Promise.resolve(); return this.receiver().#method(); } }";
    try checkGeneratedTemps(source, .es2015, 1, false);
}

test "#4819 native generator async preserves live source block under inner function" {
    const source = "class Box { static #method() { return 1; } static receiver() { return this; } static async run() { if (this) { return this.receiver().#method(); } } }";
    try checkGeneratedTempsWithBlock(source, .es2015, 1, false, true);
}

test "#4819 nested state callbacks keep distinct private temps beside user collision" {
    const source = "class Box { static #method() { return 1; } static receiver() { return this; } static async outer() { const _a = 5; const before = this.receiver().#method(); async function inner() { return Box.receiver().#method(); } await 0; return _a + before + await inner(); } }";
    try checkGeneratedTemps(source, .es5, 2, true);
}

test "#4819 for-await extracted loop temps preserve live scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const fns = [], out = [];
        \\(async () => {
        \\  for await (const value of [{ n: 1 }, null]) {
        \\    fns.push(() => value);
        \\    for (const item of [value]) out.push(item?.n ?? 'x');
        \\    for (const key in value ?? {}) out.push(key);
        \\  }
        \\})();
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    var header_scope: ?@import("../semantic/scope.zig").ScopeId = null;
    for (analyzer.symbols.items) |symbol| {
        if (std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) header_scope = symbol.scope_id;
    }
    const original_header_scope = header_scope orelse return error.TestUnexpectedResult;
    const source_function = analyzer.scopes.items[original_header_scope.toIndex()].parent;
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .emit_runtime_helper_imports = true,
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
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const wrapper = edited.scopes[original_header_scope.toIndex()].parent;
    try std.testing.expect(wrapper != source_function);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
    try std.testing.expectEqual(source_function, edited.scopes[wrapper.toIndex()].parent);
    var live_owners: usize = 0;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        if (owner.value_ptr.* != @intFromEnum(wrapper)) continue;
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, owner.key_ptr.*) != null);
        const function = transformer.ast.nodes.items[owner.key_ptr.*];
        try std.testing.expectEqual(ast_mod.Node.Tag.function_expression, function.tag);
        try std.testing.expect(transformer.readU32(function.data.extra, ast_mod.FunctionExtra.flags) & ast_mod.FunctionFlags.is_generator != 0);
        live_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live_owners);
}
