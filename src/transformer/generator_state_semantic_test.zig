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
    return checkStateScopesAtTarget(source, expected_states, wrapped, expected_deferred_loops, .es5);
}

fn checkStateScopesAtTarget(source: []const u8, expected_states: usize, wrapped: bool, expected_deferred_loops: usize, target: TransformOptions.compat.ESTarget) !void {
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

    if (target == .es2015) {
        var inner_temps: usize = 0;
        for (edited.symbols.items[original_symbol_count..]) |symbol| {
            if (symbol.kind != .variable_var or !std.mem.startsWith(u8, symbol.synthetic_name, "_")) continue;
            try std.testing.expect(symbol.scope_id.toIndex() >= analyzer.scopes.items.len);
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);
            inner_temps += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), inner_temps);
    }

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
            if (@intFromEnum(ref.symbol_id) == helper_id and ref.scope_id == parent and ref.flags.read) {
                try std.testing.expect(reachable.contains(@intFromEnum(ref.node_index)));
                try std.testing.expectEqual(@as(?u32, @intCast(helper_id)), edited.symbol_ids[@intFromEnum(ref.node_index)]);
                helper_refs_in_parent += 1;
            }
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

test "#4819 async generator native inner function binds generated body temp" {
    try checkStateScopesAtTarget(
        "export async function* stream(source) { yield source() ?? 1; }",
        0,
        false,
        0,
        .es2015,
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

test "#4819 decorated field preserves explicit constructor and nested async state owners" {
    try checkStateScopes(
        "function logged(value) { return value; } export class Box { @logged field = 1; constructor() { this.load = async () => await Promise.resolve(this.field); } }",
        1,
        true,
        0,
    );
}

test "#4819 static class generator method owns its state callback" {
    try checkStateScopes(
        "export class Box { static *read(value) { yield value + 1; } }",
        1,
        false,
        0,
    );
}

test "#4819 class expression async method owns its state callback" {
    try checkStateScopes(
        "export const Box = class { async load(value) { return await Promise.resolve(value + 1); } };",
        1,
        true,
        0,
    );
}

test "#4819 computed object async method after spread owns its state callback" {
    try checkStateScopes(
        "const key = 'load'; export const box = { ...{}, async [key](value) { return await Promise.resolve(value + 1); } };",
        1,
        true,
        0,
    );
}

test "#4819 source state name collision retains generated state symbol" {
    try checkStateScopes(
        "export function* read() { let _state = 3; yield _state; }",
        1,
        false,
        0,
    );
}

test "#4819 async generator moves body scope frontier under inner function and keeps parameter defaults outside" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const fallback = [1];
        \\export async function* stream(sLong = (() => fallback)(), tLong = ['x']) {
        \\  @((value) => value)
        \\  class Local {}
        \\  for await (const aLong of sLong) {
        \\    for (const bLong of tLong) {
        \\      const read = () => aLong + bLong;
        \\      yield read();
        \\    }
        \\  }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var source_scope: ?u32 = null;
    var body_scope: ?u32 = null;
    var default_scope: ?u32 = null;
    var decorator_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, i| {
        const scope = analyzer.scope_owner_map.get(@as(u32, @intCast(i))) orelse continue;
        switch (node.tag) {
            .function_declaration => source_scope = scope,
            .for_await_of_statement => body_scope = scope,
            .arrow_function_expression => {
                if (default_scope == null) {
                    default_scope = scope;
                } else if (decorator_scope == null) {
                    decorator_scope = scope;
                }
            },
            else => {},
        }
    }
    const outer = source_scope orelse return error.TestUnexpectedResult;
    const body = body_scope orelse return error.TestUnexpectedResult;
    const param = default_scope orelse return error.TestUnexpectedResult;
    const decorator = decorator_scope orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(outer, @intFromEnum(analyzer.scopes.items[param].parent));
    try std.testing.expectEqual(outer, @intFromEnum(analyzer.scopes.items[decorator].parent));

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
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
    const inner = edited.scopes[body].parent;
    try std.testing.expect(inner != .none and @intFromEnum(inner) != outer);
    try std.testing.expectEqual(outer, @intFromEnum(edited.scopes[inner.toIndex()].parent));
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[inner.toIndex()].kind);
    try std.testing.expectEqual(outer, @intFromEnum(edited.scopes[param].parent));
    try std.testing.expectEqual(inner, edited.scopes[decorator].parent);
    try std.testing.expectEqual(edited.scopes[outer].is_strict, edited.scopes[inner.toIndex()].is_strict);
}

test "#4819 private async method produces a scoped state callback" {
    try checkStateScopes(
        "export class Box { async #load(value) { return await Promise.resolve(value + 1); } read() { return this.#load(1); } }",
        1,
        true,
        0,
    );
}

test "#4819 private generator method produces a scoped state callback" {
    try checkStateScopes(
        "export class Box { *#read(value) { yield value + 1; } read() { return [...this.#read(1)]; } }",
        1,
        false,
        0,
    );
}

test "#4819 private async generator method produces a scoped state callback" {
    try checkStateScopes(
        "export class Box { async *#stream(value) { yield await Promise.resolve(value + 1); } read() { return this.#stream(1); } }",
        1,
        true,
        0,
    );
}

test "#4819 extracted private method functions own their exact source scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        "class Box { async #load() { await Promise.resolve(1); } " ++
        "*#read() { yield 2; } async *#stream() { yield await Promise.resolve(3); } }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var source_owners: std.ArrayList(struct { node: u32, scope: u32 }) = .empty;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const key_idx: ast_mod.NodeIndex = @enumFromInt(parser.ast.extra_data.items[node.data.extra + ast_mod.MethodExtra.key]);
        if (parser.ast.getNode(key_idx).tag != .private_identifier) continue;
        const owner = @as(u32, @intCast(index));
        try source_owners.append(allocator, .{ .node = owner, .scope = analyzer.scope_owner_map.get(owner).? });
    }
    try std.testing.expectEqual(@as(usize, 3), source_owners.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
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
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    for (source_owners.items) |source_owner| {
        try std.testing.expect(edited.scope_owner_map.get(source_owner.node) == null);
        var final_owners: usize = 0;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != source_owner.scope) continue;
            try std.testing.expectEqual(ast_mod.Node.Tag.function_declaration, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, entry.key_ptr.*) != null);
            final_owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), final_owners);
    }
}

test "#4819 static private async method owns its state callback" {
    try checkStateScopes(
        "export class Box { static async #load(value) { return await Promise.resolve(value + 1); } static read() { return this.#load(1); } }",
        1,
        true,
        0,
    );
}

test "#4819 static private generator method owns its state callback" {
    try checkStateScopes(
        "export class Box { static *#read(value) { yield value + 1; } static read() { return [...this.#read(1)]; } }",
        1,
        false,
        0,
    );
}

test "#4819 static private async generator method owns its state callback" {
    try checkStateScopes(
        "export class Box { static async *#stream(value) { yield await Promise.resolve(value + 1); } static read() { return this.#stream(1); } }",
        1,
        true,
        0,
    );
}
