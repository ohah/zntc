const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const ast_mod = @import("../parser/ast.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const Reference = @import("../semantic/symbol.zig").Reference;
const symbol_coverage = @import("symbol_coverage.zig");
const output_scope = @import("output_scope_test_utils.zig");
const es_helpers = @import("es_helpers.zig");

const DeferredStateCallback = struct {
    callback: ast_mod.NodeIndex,
    parameter: ast_mod.NodeIndex,
    reference: ast_mod.NodeIndex,
};

fn makeDeferredStateCallback(transformer: *Transformer) !DeferredStateCallback {
    const span = try transformer.ast.addString("_state");
    const parameter = try es_helpers.makeSyntheticBinding(transformer, span);
    const reference = try es_helpers.makeExactSyntheticRefFromSpan(transformer, transformer.ast.getNode(parameter).data.string_ref);
    const reference_statement = try transformer.ast.addNode(.{
        .tag = .expression_statement,
        .span = .EMPTY,
        .data = .{ .unary = .{ .operand = reference, .flags = 0 } },
    });
    const body_list = try transformer.ast.addNodeList(&.{reference_statement});
    const body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = body_list },
    });
    const params_list = try transformer.ast.addNodeList(&.{parameter});
    const params = try transformer.ast.addFormalParameters(params_list, .EMPTY);
    const none = @intFromEnum(ast_mod.NodeIndex.none);
    const extra = try transformer.ast.addExtras(&.{ none, @intFromEnum(params), @intFromEnum(body), 0, none });
    const callback = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = extra },
    });
    return .{ .callback = callback, .parameter = parameter, .reference = reference };
}

fn scopeHasAncestor(scopes: []const @import("../semantic/scope.zig").Scope, descendant: u32, ancestor: u32) bool {
    var current = descendant;
    var hops: usize = 0;
    while (current < scopes.len and hops < scopes.len) : (hops += 1) {
        const parent = scopes[current].parent;
        if (parent.isNone()) return false;
        if (@intFromEnum(parent) == ancestor) return true;
        current = @intFromEnum(parent);
    }
    return false;
}

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
    const root = try transformer.transform();
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
    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);

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
        } else if (expected_deferred_loops > 0 and !source_scopes.contains(@intFromEnum(parent))) {
            // An extracted generator loop owns its own state callback. The
            // callback's immediate parent is the synthetic loop function;
            // that function is then nested beneath the source callback.
            try std.testing.expect(!source_scopes.contains(@intFromEnum(parent)));
            try std.testing.expect(parent.toIndex() >= analyzer.scopes.items.len);
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[parent.toIndex()].kind);
            var ancestor = edited.scopes[parent.toIndex()].parent;
            var found_source_ancestor = false;
            for (0..edited.scopes.len) |_| {
                if (ancestor.isNone() or ancestor.toIndex() >= edited.scopes.len) break;
                if (source_scopes.contains(@intFromEnum(ancestor))) {
                    found_source_ancestor = true;
                    break;
                }
                ancestor = edited.scopes[ancestor.toIndex()].parent;
            }
            try std.testing.expect(found_source_ancestor);
            try std.testing.expect(!parent.isNone());
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[parent.toIndex()].kind);
            var parent_owners: usize = 0;
            var parent_owners_iter = edited.scope_owner_map.iterator();
            while (parent_owners_iter.next()) |entry| {
                if (entry.value_ptr.* != @intFromEnum(parent)) continue;
                try std.testing.expect(reachable.contains(entry.key_ptr.*));
                const owner_tag = transformer.ast.nodes.items[entry.key_ptr.*].tag;
                try std.testing.expect(owner_tag == .function_expression or owner_tag == .function_declaration);
                parent_owners += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), parent_owners);
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
            const expected_scope = output_scope.expectedScope(
                transformer.ast,
                root,
                &output_parents,
                &edited.scope_owner_map,
                @intFromEnum(ref.node_index),
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_scope, ref.scope_id);
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
    try std.testing.expectEqual(@as(usize, 0), transformer.deferred_generator_loop_migrations.count());
    var deferred = transformer.deferred_generator_loop_owners.iterator();
    while (deferred.next()) |entry| {
        try std.testing.expect(entry.key_ptr.* >= transformer.parser_node_count);
        try std.testing.expectEqual(ast_mod.Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
        try std.testing.expect(!reachable.contains(entry.key_ptr.*));
        try std.testing.expect(entry.value_ptr.function_scope != null);
        try std.testing.expect(entry.value_ptr.migration_complete);
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

test "#4819 generated function name binds its exact output function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;

    const name_span = try transformer.ast.addString("_generatedFunction");
    const name = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const empty_list = try transformer.ast.addNodeList(&.{});
    const params = try transformer.ast.addFormalParameters(empty_list, .EMPTY);
    const body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = empty_list },
    });
    const none = @intFromEnum(ast_mod.NodeIndex.none);
    const extra = try transformer.ast.addExtras(&.{ @intFromEnum(name), @intFromEnum(params), @intFromEnum(body), 0, none });
    const generated_function = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = extra },
    });
    const declaration_name_span = try transformer.ast.addString("_generatedDeclaration");
    const declaration_name = try es_helpers.makeSyntheticBinding(&transformer, declaration_name_span);
    const declaration_empty_list = try transformer.ast.addNodeList(&.{});
    const declaration_params = try transformer.ast.addFormalParameters(declaration_empty_list, .EMPTY);
    const declaration_body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = declaration_empty_list },
    });
    const declaration_extra = try transformer.ast.addExtras(&.{
        @intFromEnum(declaration_name), @intFromEnum(declaration_params), @intFromEnum(declaration_body), 0, none,
    });
    const generated_declaration = try transformer.ast.addNode(.{
        .tag = .function_declaration,
        .span = .EMPTY,
        .data = .{ .extra = declaration_extra },
    });

    try transformer.completeGeneratedStateSymbols(generated_function, transformer.programScope());
    try transformer.completeGeneratedStateSymbols(generated_declaration, transformer.programScope());
    const id = transformer.getSymbolIdAt(name) orelse return error.TestUnexpectedResult;
    const owner = transformer.outputOwnedScope(generated_function) orelse return error.TestUnexpectedResult;
    const declaration_id = transformer.getSymbolIdAt(declaration_name) orelse return error.TestUnexpectedResult;
    const editor = &transformer.semantic_editor.?;
    const symbol = editor.symbols.items[id];
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.function_decl, symbol.kind);
    try std.testing.expectEqual(owner, symbol.scope_id);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, editor.scopes.items[owner.toIndex()].kind);
    try std.testing.expectEqual(@as(?usize, id), editor.scope_maps.items[owner.toIndex()].get("_generatedFunction"));
    try std.testing.expectEqual(transformer.programScope(), editor.symbols.items[declaration_id].scope_id);
    try std.testing.expectEqual(@as(?usize, declaration_id), editor.scope_maps.items[transformer.programScope().toIndex()].get("_generatedDeclaration"));
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
        2, // source generator plus the extracted per-iteration generator
        false,
        1,
    );
}

test "#4819 extracted generator loop binding and call share exact identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const _loop = 7;
        \\export function* collect(limit) {
        \\  for (let index = 0; index < limit; index++) {
        \\    yield () => index + _loop;
        \\    for (let inner = 0; inner < 2; inner++) {
        \\      yield () => index + inner + _loop;
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
    const original_symbol_count = analyzer.symbols.items.len;

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
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);

    var loop_calls: std.AutoHashMapUnmanaged(u32, ast_mod.NodeIndex) = .empty;
    defer loop_calls.deinit(allocator);
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .call_expression) continue;
        const callee: ast_mod.NodeIndex = @enumFromInt(transformer.ast.extra_data.items[node.data.extra]);
        if (transformer.ast.getNode(callee).tag != .identifier_reference) continue;
        const maybe_id = if (@intFromEnum(callee) < edited.symbol_ids.len) edited.symbol_ids[@intFromEnum(callee)] else null;
        const id = maybe_id orelse continue;
        if (id < original_symbol_count) continue;
        const name = transformer.ast.getText(transformer.ast.getNode(callee).data.string_ref);
        if (!std.mem.startsWith(u8, name, "_loop")) continue;
        const call_entry = try loop_calls.getOrPut(allocator, id);
        try std.testing.expect(!call_entry.found_existing);
        call_entry.value_ptr.* = callee;
    }
    try std.testing.expectEqual(@as(usize, 2), loop_calls.count());
    var loop_entries = loop_calls.iterator();
    while (loop_entries.next()) |entry| {
        const id_raw = entry.key_ptr.*;
        const loop_call = entry.value_ptr.*;
        const scope = edited.symbols.items[id_raw].scope_id;
        const symbol = edited.symbols.items[id_raw];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
        const name = transformer.ast.getText(symbol.name);
        try std.testing.expect(std.mem.startsWith(u8, name, "_loop"));
        try std.testing.expectEqual(@as(?usize, id_raw), edited.scope_maps[scope.toIndex()].get(name));

        var binding_count: usize = 0;
        var call_count: usize = 0;
        var reference_count: u32 = 0;
        var write_count: u32 = 0;
        for (reachable) |raw| {
            if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != id_raw) continue;
            const node = transformer.ast.nodes.items[raw];
            if (node.tag == .binding_identifier) {
                binding_count += 1;
                const binding_scope = output_scope.expectedScope(
                    transformer.ast,
                    root,
                    &output_parents,
                    &edited.scope_owner_map,
                    raw,
                ) orelse return error.TestUnexpectedResult;
                try std.testing.expectEqual(scope, binding_scope);
            } else if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                if (raw == @intFromEnum(loop_call)) call_count += 1;
                var has_reference = false;
                for (edited.references) |reference| {
                    if (@intFromEnum(reference.node_index) != raw) continue;
                    try std.testing.expectEqual(id_raw, @intFromEnum(reference.symbol_id));
                    const expected_scope = output_scope.expectedScope(
                        transformer.ast,
                        root,
                        &output_parents,
                        &edited.scope_owner_map,
                        raw,
                    ) orelse return error.TestUnexpectedResult;
                    try std.testing.expectEqual(expected_scope, reference.scope_id);
                    try std.testing.expect(reference.flags.read or reference.flags.write);
                    try std.testing.expect(!reference.flags.declare);
                    if (raw == @intFromEnum(loop_call))
                        try std.testing.expect(reference.flags.read and !reference.flags.write);
                    if (reference.flags.write) write_count += 1;
                    var cursor = reference.scope_id;
                    var visible = false;
                    for (0..edited.scopes.len) |_| {
                        if (cursor.isNone() or cursor.toIndex() >= edited.scopes.len) break;
                        if (cursor == scope) {
                            visible = true;
                            break;
                        }
                        cursor = edited.scopes[cursor.toIndex()].parent;
                    }
                    try std.testing.expect(visible);
                    has_reference = true;
                    reference_count += 1;
                }
                try std.testing.expect(has_reference);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        try std.testing.expectEqual(@as(usize, 1), call_count);
        try std.testing.expectEqual(symbol.reference_count, reference_count);
        try std.testing.expectEqual(symbol.write_count, write_count);
        try std.testing.expect(write_count >= 1);
    }
}

test "#4819 extracted generator loop has exact header and catch symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const log = [];
        \\function* gLong() {
        \\  for (let iLong = 0; iLong < 2; iLong++) {
        \\    try {
        \\      throw iLong;
        \\    } catch (eLong) {
        \\      yield 0;
        \\      log.push(() => eLong);
        \\      log.push((iLong) => iLong);
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
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var report = try symbol_coverage.checkStrict(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        &analyzer.unresolved_references,
    );
    defer report.deinit(allocator);

    var saw_i_binding = false;
    var saw_i_reference = false;
    var saw_e_binding = false;
    var saw_e_reference = false;
    for (report.findings.items) |finding| {
        const suffix = std.mem.lastIndexOfScalar(u8, finding.name, '$');
        const base = if (suffix) |index| finding.name[0..index] else finding.name;
        const is_i = std.mem.eql(u8, base, "iLong");
        const is_e = std.mem.eql(u8, base, "eLong");
        if (!is_i and !is_e) continue;
        try std.testing.expectEqual(symbol_coverage.StrictStatus.bound, finding.status);
        if (finding.tag == .binding_identifier) {
            if (is_i) saw_i_binding = true else saw_e_binding = true;
        } else if (finding.tag == .identifier_reference or finding.tag == .assignment_target_identifier) {
            if (is_i) saw_i_reference = true else saw_e_reference = true;
        }
    }
    try std.testing.expect(saw_i_binding);
    try std.testing.expect(saw_i_reference);
    try std.testing.expect(saw_e_binding);
    try std.testing.expect(saw_e_reference);
}

test "#4819 extracted generator control-flow temps reuse their exact ret names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function* g() {
        \\  const _ret = 99;
        \\  for (let i = 0; i < 2; i++) {
        \\    if (i === 0) return 1;
        \\    yield () => i;
        \\  }
        \\  for (let j = 0; j < 2; j++) {
        \\    if (j === 0) return 2;
        \\    yield () => j;
        \\  }
        \\  yield _ret;
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbol_count = analyzer.symbols.items.len;

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

    var generated_ret_temps: usize = 0;
    for (edited.symbols.items[original_symbol_count..]) |symbol| {
        if (symbol.kind != .variable_var or !std.mem.startsWith(u8, symbol.synthetic_name, "_ret")) continue;
        generated_ret_temps += 1;
        try std.testing.expect(symbol.reference_count > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), generated_ret_temps);
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
    var inner = edited.scopes[body].parent;
    while (!inner.isNone() and edited.scopes[inner.toIndex()].kind != .function) {
        inner = edited.scopes[inner.toIndex()].parent;
    }
    try std.testing.expect(inner != .none and @intFromEnum(inner) != outer);
    // The downlevel for-await try/finally introduces a block between the
    // generated async callback and its source function.
    try std.testing.expect(scopeHasAncestor(edited.scopes, @intFromEnum(inner), outer));
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[inner.toIndex()].kind);
    try std.testing.expectEqual(outer, @intFromEnum(edited.scopes[param].parent));
    try std.testing.expect(scopeHasAncestor(edited.scopes, decorator, inner.toIndex()));
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

test "#4819 deferred state symbols bind only their recorded callback nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _state = 0; const _state2 = 1;");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const first = try makeDeferredStateCallback(&transformer);
    const second = try makeDeferredStateCallback(&transformer);
    const unrelated = try makeDeferredStateCallback(&transformer);
    const dead = try makeDeferredStateCallback(&transformer);
    const orphan_reference = try es_helpers.makeExactSyntheticRefFromSpan(
        &transformer,
        transformer.ast.getNode(first.parameter).data.string_ref,
    );
    try std.testing.expectEqualStrings("_state3", transformer.ast.getText(transformer.ast.getNode(first.parameter).data.string_ref));
    try transformer.generator_state_refs.appendSlice(allocator, &.{ first.reference, first.reference, orphan_reference });
    try transformer.bindGeneratedState(.none, .none, first.callback, first.parameter, 0, &.{}, &.{}, .EMPTY);
    try transformer.generator_state_refs.append(allocator, second.reference);
    try transformer.bindGeneratedState(.none, .none, second.callback, second.parameter, 0, &.{}, &.{}, .EMPTY);
    try transformer.generator_state_refs.append(allocator, dead.reference);
    try transformer.bindGeneratedState(.none, .none, dead.callback, dead.parameter, 0, &.{}, &.{}, .EMPTY);

    const first_stmt = try transformer.ast.addNode(.{
        .tag = .expression_statement,
        .span = .EMPTY,
        .data = .{ .unary = .{ .operand = first.callback, .flags = 0 } },
    });
    const second_stmt = try transformer.ast.addNode(.{
        .tag = .expression_statement,
        .span = .EMPTY,
        .data = .{ .unary = .{ .operand = second.callback, .flags = 0 } },
    });
    const unrelated_stmt = try transformer.ast.addNode(.{
        .tag = .expression_statement,
        .span = .EMPTY,
        .data = .{ .unary = .{ .operand = unrelated.callback, .flags = 0 } },
    });
    const root_list = try transformer.ast.addNodeList(&.{ first_stmt, second_stmt, unrelated_stmt });
    const root = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = root_list },
    });
    const program_scope = transformer.programScope();
    try transformer.registerGeneratedFunctionScopes(root, program_scope);
    try transformer.completeGeneratedStateSymbols(root, program_scope);

    const first_id = transformer.getSymbolIdAt(first.parameter).?;
    const second_id = transformer.getSymbolIdAt(second.parameter).?;
    try std.testing.expect(first_id != second_id);
    try std.testing.expectEqual(first_id, transformer.getSymbolIdAt(first.reference).?);
    try std.testing.expectEqual(second_id, transformer.getSymbolIdAt(second.reference).?);
    try std.testing.expect(transformer.getSymbolIdAt(orphan_reference) == null);
    try std.testing.expect(transformer.getSymbolIdAt(dead.parameter) == null);
    try std.testing.expect(transformer.getSymbolIdAt(dead.reference) == null);
    // The name looks like a state parameter, but no state-machine producer
    // recorded it. It must stay untouched instead of being inferred by name.
    try std.testing.expect(transformer.getSymbolIdAt(unrelated.parameter) == null);
    try std.testing.expectEqual(@as(usize, 0), transformer.deferred_generated_state_symbols.items.len);

    const editor = &transformer.semantic_editor.?;
    const first_scope = transformer.outputOwnedScope(first.callback).?;
    const second_scope = transformer.outputOwnedScope(second.callback).?;
    const first_reference = (try editor.referenceForNode(first.reference)).?;
    const second_reference = (try editor.referenceForNode(second.reference)).?;
    try std.testing.expectEqual(first_id, @intFromEnum(first_reference.symbol_id));
    try std.testing.expectEqual(second_id, @intFromEnum(second_reference.symbol_id));
    try std.testing.expectEqual(first_scope, first_reference.scope_id);
    try std.testing.expectEqual(second_scope, second_reference.scope_id);
}
