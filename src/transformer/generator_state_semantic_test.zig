const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const ast_mod = @import("../parser/ast.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const Reference = @import("../semantic/symbol.zig").Reference;

fn checkStateScopes(source: []const u8, expected_states: usize, wrapped: bool, expected_deferred_loops: usize) !void {
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
    const original_symbol_count = analyzer.symbols.items.len;

    var source_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var owner_it = analyzer.scope_owner_map.iterator();
    while (owner_it.next()) |entry| {
        const tag = parser.ast.nodes.items[entry.key_ptr.*].tag;
        if (tag == .function_declaration or tag == .function_expression or
            tag == .arrow_function_expression or tag == .method_definition)
            try source_scopes.put(allocator, entry.value_ptr.*, {});
    }

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

    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const nodes = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    for (nodes) |node| try reachable.put(allocator, node, {});

    var found: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind != .parameter or !std.mem.startsWith(u8, symbol.synthetic_name, "_state")) continue;
        found += 1;
        const callback_scope = symbol.scope_id;
        try std.testing.expectEqual(@as(u32, @intCast(symbol_index)), edited.scope_maps[callback_scope.toIndex()].get(symbol.synthetic_name).?);
        var callback_owners: usize = 0;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @intFromEnum(callback_scope)) continue;
            try std.testing.expect(reachable.contains(entry.key_ptr.*));
            try std.testing.expectEqual(ast_mod.Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            callback_owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), callback_owners);

        const parent = edited.scopes[callback_scope.toIndex()].parent;
        if (wrapped) {
            try std.testing.expect(!source_scopes.contains(@intFromEnum(parent)));
            try std.testing.expect(source_scopes.contains(@intFromEnum(edited.scopes[parent.toIndex()].parent)));
        } else {
            try std.testing.expect(source_scopes.contains(@intFromEnum(parent)));
        }

        var bindings: usize = 0;
        for (nodes) |node| {
            if (transformer.ast.nodes.items[node].tag != .binding_identifier) continue;
            if (node < edited.symbol_ids.len and edited.symbol_ids[node] == @as(u32, @intCast(symbol_index))) bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);

        var reads: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != symbol_index or ref.node_index.isNone()) continue;
            try std.testing.expect(reachable.contains(@intFromEnum(ref.node_index)));
            try std.testing.expectEqual(callback_scope, ref.scope_id);
            try std.testing.expect(ref.flags.read and !ref.flags.write and !ref.flags.declare);
            try std.testing.expectEqual(Reference.NO_STMT, ref.stmt_idx);
            try std.testing.expectEqual(Reference.NO_STMT, ref.scope_stmt_idx);
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@intFromEnum(ref.node_index)]);
            reads += 1;
        }
        try std.testing.expect(reads >= 2);
        try std.testing.expectEqual(@as(u32, @intCast(reads)), symbol.reference_count);
        try std.testing.expectEqual(@as(u32, 0), symbol.write_count);

        // The helper call is inside the async wrapper, or directly in the
        // generator function. It must not inherit the transform cursor scope.
        const helper_id = edited.helper_scope_map.get("__generator").?;
        var helper_refs_in_parent: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) == helper_id and ref.scope_id == parent and ref.flags.read)
                helper_refs_in_parent += 1;
        }
        // The deferred generator `_loop` still carries its pre-migration
        // helper scope, so only fully registered callbacks have a 1:1 count.
        if (expected_deferred_loops == 0) {
            try std.testing.expectEqual(@as(usize, 1), helper_refs_in_parent);
        } else {
            try std.testing.expect(helper_refs_in_parent >= 1);
        }
    }
    try std.testing.expectEqual(expected_states, found);
    try std.testing.expectEqual(@as(usize, 0), transformer.generator_state_refs.items.len);
    try std.testing.expectEqual(expected_deferred_loops, transformer.deferred_generator_loop_owners.count());
    var deferred = transformer.deferred_generator_loop_owners.iterator();
    while (deferred.next()) |entry| {
        try std.testing.expect(entry.key_ptr.* >= transformer.parser_node_count);
        try std.testing.expectEqual(ast_mod.Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
        try std.testing.expect(!reachable.contains(entry.key_ptr.*));
    }
}

test "#4819 generator state nested callbacks use distinct source function scopes" {
    try checkStateScopes(
        "export function* outer() { yield 1; const inner = function*() { yield 2; }; yield inner().next().value; }",
        2,
        false,
        0,
    );
}

test "#4819 generated state binding stays separate from user _state parameter" {
    try checkStateScopes(
        "export function* read(_state) { yield _state; }",
        1,
        false,
        0,
    );
}

test "#4819 async function state callback and helper use real wrapper scope" {
    try checkStateScopes(
        "export async function run(value) { try { await Promise.resolve(value); } catch (err) { return err; } return await Promise.resolve(2); }",
        1,
        true,
        0,
    );
}

test "#4819 async arrow state callback and helper use real wrapper scope" {
    try checkStateScopes(
        "export const run = async (value) => { await Promise.resolve(value); return value; };",
        1,
        true,
        0,
    );
}

test "#4819 class async method state callback and helper use real wrapper scope" {
    try checkStateScopes(
        "export class Box { async load(value) { await Promise.resolve(value); return value; } }",
        1,
        true,
        0,
    );
}

test "#4819 object async method state callback and helper use real wrapper scope" {
    try checkStateScopes(
        "export const box = { async load(value) { await Promise.resolve(value); return value; } };",
        1,
        true,
        0,
    );
}

test "#4819 nested async arrow in class method keeps separate state owners" {
    try checkStateScopes(
        "export class Box { async load(value) { const nested = async () => await Promise.resolve(value + 1); return await nested(); } }",
        2,
        true,
        0,
    );
}

test "#4819 nested async arrow in object method keeps separate state owners" {
    try checkStateScopes(
        "export const box = { async load(value) { const nested = async () => await Promise.resolve(value + 1); return await nested(); } };",
        2,
        true,
        0,
    );
}

test "#4819 generated loop state explicitly waits for generator loop migration" {
    try checkStateScopes(
        "export function* collect() { for (let index = 0; index < 2; index++) { yield () => index; } }",
        1,
        false,
        1,
    );
}

test "#4819 async generator inner function owns its ES5 state callback" {
    try checkStateScopes(
        "export async function* stream() { yield await Promise.resolve(1); }",
        1,
        true,
        0,
    );
}

test "#4819 class async generator inner function owns its ES5 state callback" {
    try checkStateScopes(
        "export class Box { async *stream() { yield await Promise.resolve(1); } }",
        1,
        true,
        0,
    );
}

test "#4819 computed class async method retains its original state owner" {
    try checkStateScopes(
        "const key = 'load'; export class Box { field = 1; async [key](value) { return await Promise.resolve(value + this.field); } }",
        1,
        true,
        0,
    );
}

test "#4819 computed class generator method retains its original state owner" {
    try checkStateScopes(
        "const key = 'read'; export class Box { *[key](value) { yield value + 1; } }",
        1,
        false,
        0,
    );
}

test "#4819 computed class async generator method retains its original state owner" {
    try checkStateScopes(
        "const key = 'read'; export class Box { async *[key](value) { yield await Promise.resolve(value + 1); } }",
        1,
        true,
        0,
    );
}

test "#4819 computed object async method retains its original state owner" {
    try checkStateScopes(
        "const key = 'load'; export const box = { async [key](value) { return await Promise.resolve(value + 1); } };",
        1,
        true,
        0,
    );
}

test "#4819 decorated computed class async method retains its original state owner" {
    try checkStateScopes(
        "const key = 'load'; function logged(value) { return value; } export class Box { @logged async [key](value) { return await Promise.resolve(value + 1); } }",
        1,
        true,
        0,
    );
}
