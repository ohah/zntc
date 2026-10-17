const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const ast_mod = @import("../parser/ast.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const Reference = @import("../semantic/symbol.zig").Reference;
const output_scope = @import("output_scope_test_utils.zig");
const es_helpers = @import("es_helpers.zig");
const BlockScoping = @import("es2015_block_scoping.zig").ES2015BlockScoping(Transformer);

fn checkGeneratedTemps(source: []const u8, target: TransformOptions.compat.ESTarget, expected: usize, has_state: bool) !void {
    return checkGeneratedTempsWithBlock(source, target, expected, has_state, false);
}

fn checkGeneratedTempsWithBlock(source: []const u8, target: TransformOptions.compat.ESTarget, expected: usize, has_state: bool, expect_block_refs: bool) !void {
    return checkGeneratedTempsWithBlockAndLateNames(source, target, expected, has_state, expect_block_refs, false, false, null);
}

fn checkGeneratedTempsWithLateNames(source: []const u8, target: TransformOptions.compat.ESTarget, expected: usize, has_state: bool, expect_late_names: bool) !void {
    return checkGeneratedTempsWithBlockAndLateNames(source, target, expected, has_state, false, true, expect_late_names, null);
}

fn checkGeneratedTempsWithBlockAndLateNames(source: []const u8, target: TransformOptions.compat.ESTarget, expected: usize, has_state: bool, expect_block_refs: bool, late_name_mode: bool, expect_late_names: bool, preserve_source_name: ?[]const u8) !void {
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
        .emit_runtime_helper_imports = !late_name_mode,
        .defer_runtime_helper_name_resolution = late_name_mode,
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
    if (preserve_source_name) |name| {
        var matched: usize = 0;
        for (analyzer.symbols.items, 0..) |_, source_id| {
            const symbol = edited.symbols.items[source_id];
            if (!std.mem.eql(u8, symbol.nameText(parser.ast.source), name)) continue;
            matched += 1;
            try std.testing.expect(symbol.synthetic_kind == null);
            try std.testing.expectEqual(@as(?usize, source_id), edited.scope_maps[@backingInt(symbol.scope_id)].get(symbol.nameText(parser.ast.source)));
        }
        try std.testing.expectEqual(@as(usize, 1), matched);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);

    var found: usize = 0;
    for (edited.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind != .variable_var or symbol.synthetic_name.len < 2 or symbol.synthetic_name[0] != '_') continue;
        // The private receiver expression creates one write and two reads.
        if (symbol.reference_count != 3 or symbol.write_count != 1) continue;
        found += 1;
        if (late_name_mode) {
            try std.testing.expectEqual(expect_late_names, symbol.synthetic_kind == .standalone_temp_binding);
            try std.testing.expectEqual(@as(?usize, symbol_index), edited.scope_maps[@backingInt(symbol.scope_id)].get(symbol.synthetic_name));
        }
        try std.testing.expect(symbol.scope_id.toIndex() >= analyzer.scopes.items.len);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);
        var owner_count: usize = 0;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(symbol.scope_id)) continue;
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
            if (@backingInt(ref.symbol_id) != symbol_index or ref.node_index.isNone()) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(ref.node_index)) != null);
            const expected_scope = output_scope.expectedScope(
                transformer.ast,
                root,
                &output_parents,
                &edited.scope_owner_map,
                @backingInt(ref.node_index),
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_scope, ref.scope_id);
            if (expect_block_refs) {
                try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, edited.scopes[ref.scope_id.toIndex()].kind);
                try std.testing.expectEqual(symbol.scope_id, edited.scopes[ref.scope_id.toIndex()].parent);
            }
            try std.testing.expectEqual(Reference.NO_STMT, ref.stmt_idx);
            try std.testing.expectEqual(Reference.NO_STMT, ref.scope_stmt_idx);
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@backingInt(ref.node_index)]);
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

test "#4819 state-machine callback temps finalize by exact ID unless dynamic lookup blocks them" {
    const async_method = "class Box { static #method() { return 1; } static receiver() { return this; } static async run() { await Promise.resolve(); return this.receiver().#method(); } }";
    const generator_method = "class Box { static #method() { return 1; } static receiver() { return this; } static *run() { var sourceValue = 5; yield this.receiver().#method() + sourceValue; } }";
    const eval_blocks = "class Box { static #method() { return 1; } static receiver() { return this; } static async run() { await Promise.resolve(); return this.receiver().#method(); } } function sibling() { eval(''); }";
    try checkGeneratedTempsWithLateNames(async_method, .es5, 1, true, true);
    try checkGeneratedTempsWithBlockAndLateNames(generator_method, .es5, 1, true, false, true, true, "sourceValue");
    try checkGeneratedTempsWithLateNames(eval_blocks, .es5, 1, true, false);
}

fn checkTrackedCallbackTemp(source: []const u8, expect_late_name: bool) !void {
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

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .emit_runtime_helper_imports = false,
        .defer_runtime_helper_name_resolution = true,
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

    var source_scope = transformer.programScope();
    var found_owner_scope = false;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const name = transformer.readNodeIdx(node.data.extra, 0);
        if (name.isNone() or !std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(name).data.string_ref), "owner")) continue;
        source_scope = @fromBackingInt(@intCast(analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.MissingOwnerScope));
        found_owner_scope = true;
        break;
    }
    try std.testing.expect(found_owner_scope);

    var preserved_binding_source: ?ast_mod.NodeIndex = null;
    var preserved_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_preserved")) continue;
        preserved_binding_source = @fromBackingInt(@intCast(raw));
        preserved_id = analyzer.symbol_ids.items[raw];
    }
    const original_preserved_binding = preserved_binding_source orelse return error.MissingPreservedSourceBinding;
    const preserved_symbol_id = preserved_id orelse return error.MissingPreservedSourceSymbol;
    const preserved_span = transformer.ast.getNode(original_preserved_binding).data.string_ref;
    const preserved_binding = try es_helpers.makeSyntheticBinding(&transformer, preserved_span);
    const preserved_reference = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, preserved_span);
    const preserved_declarator = try es_helpers.makeDeclarator(&transformer, preserved_binding, ast_mod.NodeIndex.none, .EMPTY);
    const preserved_declaration = try es_helpers.makeVarDeclaration(&transformer, &.{preserved_declarator}, .@"var", .EMPTY);
    const preserved_reference_statement = try es_helpers.makeExprStmt(&transformer, preserved_reference, .EMPTY);

    const name_span = try transformer.ast.addString("_tracked");
    const binding = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const reference = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, name_span);
    const declarator = try es_helpers.makeDeclarator(&transformer, binding, ast_mod.NodeIndex.none, .EMPTY);
    const declaration = try es_helpers.makeVarDeclaration(&transformer, &.{declarator}, .@"var", .EMPTY);
    const reference_statement = try es_helpers.makeExprStmt(&transformer, reference, .EMPTY);
    const body_list = try transformer.ast.addNodeList(&.{ preserved_declaration, preserved_reference_statement, declaration, reference_statement });
    const body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = body_list },
    });
    const state_name = try transformer.ast.addString("_state");
    const state_parameter = try es_helpers.makeSyntheticBinding(&transformer, state_name);
    const callback_params_list = try transformer.ast.addNodeList(&.{state_parameter});
    const callback_params = try transformer.ast.addFormalParameters(callback_params_list, .EMPTY);
    const none = @backingInt(ast_mod.NodeIndex.none);
    const callback_extra = try transformer.ast.addExtras(&.{ none, @backingInt(callback_params), @backingInt(body), 0, none });
    const callback = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = callback_extra },
    });
    try transformer.generator_state_bindings.append(allocator, .{
        .binding = preserved_binding,
        .name_span = preserved_span,
        .symbol_id = preserved_symbol_id,
        .owner_scope = source_scope,
    });
    try transformer.generator_state_bindings.append(allocator, .{
        .binding = binding,
        .name_span = name_span,
        .callback_local = true,
    });
    try transformer.trackHoistedTempRefInScope(preserved_span, preserved_reference, source_scope, .{ .read = true });
    try transformer.trackHoistedTempRefInScope(name_span, reference, source_scope, .{ .read = true });
    try transformer.bindGeneratedState(source_scope, source_scope, callback, state_parameter, 0, &.{}, &.{}, .EMPTY);

    const editor = if (transformer.semantic_editor) |*value| value else return error.TestUnexpectedResult;
    const callback_scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(@intCast(
        editor.scope_owner_map.get(@backingInt(callback)) orelse return error.MissingCallbackScope,
    ));
    const preserved_symbol = editor.symbols.items[preserved_symbol_id];
    try std.testing.expect(preserved_symbol.synthetic_kind == null);
    try std.testing.expectEqual(@as(?u32, preserved_symbol_id), transformer.getSymbolIdAt(preserved_binding));
    try std.testing.expectEqual(source_scope, preserved_symbol.scope_id);
    try std.testing.expectEqual(
        @as(?usize, preserved_symbol_id),
        editor.scope_maps.items[source_scope.toIndex()].get(preserved_symbol.nameText(parser.ast.source)),
    );
    const preserved_reference_record = (try editor.referenceForNode(preserved_reference)) orelse return error.MissingPreservedSourceReference;
    try std.testing.expectEqual(@as(@import("../semantic/symbol.zig").SymbolId, @fromBackingInt(@intCast(preserved_symbol_id))), preserved_reference_record.symbol_id);
    try std.testing.expectEqual(callback_scope, preserved_reference_record.scope_id);
    const raw_id = transformer.getSymbolIdAt(binding) orelse return error.MissingTrackedCallbackSymbol;
    const id: usize = raw_id;
    const symbol = editor.symbols.items[id];
    try std.testing.expectEqual(callback_scope, symbol.scope_id);
    try std.testing.expectEqual(
        expect_late_name,
        symbol.synthetic_kind == .standalone_temp_binding,
    );
    try std.testing.expectEqual(@as(?usize, id), editor.scope_maps.items[callback_scope.toIndex()].get(symbol.synthetic_name));
    const reference_record = (try editor.referenceForNode(reference)) orelse return error.MissingTrackedCallbackReference;
    try std.testing.expectEqual(@as(@import("../semantic/symbol.zig").SymbolId, @fromBackingInt(@intCast(raw_id))), reference_record.symbol_id);
    try std.testing.expectEqual(callback_scope, reference_record.scope_id);
}

test "#4819 tracked callback-local temp finalizes through its exact SymbolId" {
    try checkTrackedCallbackTemp("function owner() { var _preserved = 1; } export {};", true);
    try checkTrackedCallbackTemp("function owner() { var _preserved = 1; eval(''); } export {};", false);
}

test "#4819 generator for-in temps retain their exact wrapper symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "export function* first(source) { for (const value in source) { yield value; } } export function* second(source) { for (const value in source) { yield value; } }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const source_symbol_count = analyzer.symbols.items.len;

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
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var output_parents = try output_scope.buildParentMap(allocator, transformer.ast, root);
    defer output_parents.deinit(allocator);

    const expected_names = [_][]const u8{ "_a", "_b", "_keys", "_idx", "_keys2", "_idx2" };
    var found: usize = 0;
    var a_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var a_count: usize = 0;
    var b_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var b_count: usize = 0;
    for (edited.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, symbol_index| {
        const name = transformer.ast.getText(symbol.name);
        var expected = false;
        for (expected_names) |expected_name| {
            if (std.mem.eql(u8, name, expected_name)) expected = true;
        }
        if (!expected) continue;
        found += 1;
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[symbol.scope_id.toIndex()].kind);
        if (std.mem.eql(u8, name, "_a")) {
            try std.testing.expect(a_count < a_scopes.len);
            a_scopes[a_count] = symbol.scope_id;
            a_count += 1;
        } else if (std.mem.eql(u8, name, "_b")) {
            try std.testing.expect(b_count < b_scopes.len);
            b_scopes[b_count] = symbol.scope_id;
            b_count += 1;
        }

        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var reference_count: usize = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != symbol_index or ref.node_index.isNone()) continue;
            const raw = @backingInt(ref.node_index);
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, raw) != null);
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[raw]);
            const expected_scope = output_scope.expectedScope(
                transformer.ast,
                root,
                &output_parents,
                &edited.scope_owner_map,
                raw,
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(expected_scope, ref.scope_id);
            var cursor = ref.scope_id;
            var visible = false;
            for (0..edited.scopes.len) |_| {
                if (cursor.isNone() or cursor.toIndex() >= edited.scopes.len) break;
                if (cursor == symbol.scope_id) {
                    visible = true;
                    break;
                }
                cursor = edited.scopes[cursor.toIndex()].parent;
            }
            try std.testing.expect(visible);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), a_count);
    try std.testing.expectEqual(@as(usize, 2), b_count);
    try std.testing.expect(a_scopes[0] != a_scopes[1]);
    try std.testing.expect(b_scopes[0] != b_scopes[1]);
    for (a_scopes) |scope| try std.testing.expect(scope == b_scopes[0] or scope == b_scopes[1]);
    try std.testing.expectEqual(@as(usize, 8), found);
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

test "#4819 deferred generated temp owner follows exact allocation SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export {};");
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
    transformer.semantic_edit_enabled = true;

    const source_scope = transformer.programScope();
    const name_span = try transformer.ast.addString("_deferredTemp");
    const source_binding = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const source_id = (try transformer.declareSyntheticTempInScope(source_binding, .EMPTY, source_scope)) orelse
        return error.TestUnexpectedResult;
    try transformer.bindHoistedTemp(source_binding, name_span, .EMPTY, source_scope);

    const none = @backingInt(ast_mod.NodeIndex.none);
    const hoisted_binding = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const declarator = try es_helpers.makeDeclarator(&transformer, hoisted_binding, .none, .EMPTY);
    const declaration = try es_helpers.makeVarDeclaration(&transformer, &.{declarator}, .@"var", .EMPTY);
    const body_list = try transformer.ast.addNodeList(&.{declaration});
    const body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = body_list },
    });
    const params_list = try transformer.ast.addNodeList(&.{});
    const params = try transformer.ast.addFormalParameters(params_list, .EMPTY);
    const function_extra = try transformer.ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none });
    const owner = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = function_extra },
    });
    const function_scope = try transformer.addGeneratedFunctionScope(source_scope, owner);

    const decoy_binding = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const decoy_owner_extra = try transformer.ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none });
    const decoy_owner = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = decoy_owner_extra },
    });
    const decoy_scope = try transformer.addGeneratedFunctionScope(source_scope, decoy_owner);
    const decoy_id = (try transformer.declareSyntheticInScope(decoy_binding, .EMPTY, .variable_var, decoy_scope)) orelse
        return error.TestUnexpectedResult;

    const editor = if (transformer.semantic_editor) |*value| value else return error.TestUnexpectedResult;
    const temp = @import("transformer.zig").GeneratedTempBinding{
        .binding = hoisted_binding,
        .name_span = name_span,
    };
    try transformer.bindGeneratedFunctionTemps(source_scope, function_scope, body, &.{temp}, .EMPTY);

    try std.testing.expectEqual(function_scope, editor.symbols.items[@backingInt(source_id)].scope_id);
    try std.testing.expectEqual(decoy_scope, editor.symbols.items[@backingInt(decoy_id)].scope_id);
    try std.testing.expectEqual(@as(?u32, @backingInt(source_id)), transformer.symbol_ids.items[@backingInt(hoisted_binding)]);
    try std.testing.expectEqual(@as(?u32, @backingInt(decoy_id)), transformer.symbol_ids.items[@backingInt(decoy_binding)]);
    try std.testing.expectEqual(@as(?usize, @backingInt(source_id)), editor.scope_maps.items[function_scope.toIndex()].get(transformer.ast.getText(name_span)));
    try std.testing.expect(editor.scope_maps.items[source_scope.toIndex()].get(transformer.ast.getText(name_span)) == null);
    try std.testing.expectEqual(@as(?usize, @backingInt(decoy_id)), editor.scope_maps.items[decoy_scope.toIndex()].get(transformer.ast.getText(name_span)));
}

test "#4819 using wrapper temp gets its exact owner SymbolId at production" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export {};");
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
    transformer.semantic_edit_enabled = true;

    const none = @backingInt(ast_mod.NodeIndex.none);
    const empty_list = try transformer.ast.addNodeList(&.{});
    const params = try transformer.ast.addFormalParameters(empty_list, .EMPTY);
    const owner_body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = empty_list },
    });
    const owner_extra = try transformer.ast.addExtras(&.{ none, @backingInt(params), @backingInt(owner_body), 0, none });
    const owner = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = owner_extra },
    });
    const owner_scope = try transformer.addGeneratedFunctionScope(transformer.programScope(), owner);
    transformer.current_scope = owner_scope;
    transformer.state_machine_depth = 1;
    defer transformer.state_machine_depth = 0;

    const name_span = try transformer.ast.addString("_stack");
    const binding = try es_helpers.makeSyntheticBinding(&transformer, name_span);
    const id = (try transformer.registerGeneratedWrapperTemp(binding, name_span, .EMPTY, owner_scope)) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(binding));
    try std.testing.expectEqual(owner_scope, transformer.semantic_editor.?.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expectEqual(@as(usize, 1), transformer.generator_state_bindings.items.len);
    try std.testing.expectEqual(owner_scope, transformer.generator_state_bindings.items[0].owner_scope);

    const reference = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, name_span);
    try transformer.trackHoistedTempRefInScope(name_span, reference, owner_scope, .{ .read = true });
    const statement = try transformer.ast.addNode(.{
        .tag = .expression_statement,
        .span = .EMPTY,
        .data = .{ .unary = .{ .operand = reference, .flags = 0 } },
    });
    const callback_body_list = try transformer.ast.addNodeList(&.{statement});
    const callback_body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = callback_body_list },
    });
    const state_name = try transformer.ast.addString("_state");
    const state_parameter = try es_helpers.makeSyntheticBinding(&transformer, state_name);
    const callback_params_list = try transformer.ast.addNodeList(&.{state_parameter});
    const callback_params = try transformer.ast.addFormalParameters(callback_params_list, .EMPTY);
    const callback_extra = try transformer.ast.addExtras(&.{ none, @backingInt(callback_params), @backingInt(callback_body), 0, none });
    const callback = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = callback_extra },
    });
    try transformer.bindGeneratedState(owner_scope, owner_scope, callback, state_parameter, 0, &.{}, &.{}, .EMPTY);

    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(reference));
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const editor = if (transformer.semantic_editor) |*value| value else return error.TestUnexpectedResult;
    const reference_record = (try editor.referenceForNode(reference)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(id, reference_record.symbol_id);
    try std.testing.expectEqual(owner_scope, editor.symbols.items[@backingInt(id)].scope_id);
    try std.testing.expect(reference_record.scope_id != owner_scope);
    var callback_scope_found = false;
    var owners = editor.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.key_ptr.* == @backingInt(callback) and entry.value_ptr.* == @backingInt(reference_record.scope_id))
            callback_scope_found = true;
    }
    try std.testing.expect(callback_scope_found);
}

test "#4819 callback temp reference binds through its exact producer node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export {};");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const source_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;

    const none = @backingInt(ast_mod.NodeIndex.none);
    const empty_list = try transformer.ast.addNodeList(&.{});
    const owner_params = try transformer.ast.addFormalParameters(empty_list, .EMPTY);
    const owner_body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = empty_list },
    });
    const owner_extra = try transformer.ast.addExtras(&.{ none, @backingInt(owner_params), @backingInt(owner_body), 0, none });
    const owner = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = owner_extra },
    });
    const owner_scope = try transformer.addGeneratedFunctionScope(transformer.programScope(), owner);
    transformer.current_scope = owner_scope;
    transformer.state_machine_depth = 1;
    defer transformer.state_machine_depth = 0;

    const return_statement = try transformer.ast.addNode(.{
        .tag = .return_statement,
        .span = .EMPTY,
        .data = .{ .unary = .{ .operand = .none, .flags = 0 } },
    });
    var flow = BlockScoping.FlowResult{ .has_return = true };
    defer flow.labels.deinit(allocator);
    const loop = try BlockScoping.buildLoopClosureWithFlow(
        &transformer,
        return_statement,
        &.{},
        &flow,
        null,
        .EMPTY,
        false,
        false,
        false,
        null,
        &.{},
        &.{},
        &.{},
        .none,
        .none,
    );
    try std.testing.expectEqual(@as(usize, 2), transformer.generator_state_temp_refs.items.len);
    const binding = transformer.generator_state_temp_refs.items[0].binding;
    try std.testing.expectEqual(binding, transformer.generator_state_temp_refs.items[1].binding);
    for (transformer.generator_state_temp_refs.items) |pending| {
        try std.testing.expectEqual(binding, pending.binding);
        for (transformer.pending_temp_refs.items) |by_name| {
            try std.testing.expect(by_name.node != pending.reference);
        }
    }

    const callback_body_list = try transformer.ast.addNodeList(&.{ loop.loop_fn, loop.call_and_check });
    const callback_body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = callback_body_list },
    });
    const state_name = try transformer.ast.addString("_state");
    const state_parameter = try es_helpers.makeSyntheticBinding(&transformer, state_name);
    const callback_params_list = try transformer.ast.addNodeList(&.{state_parameter});
    const callback_params = try transformer.ast.addFormalParameters(callback_params_list, .EMPTY);
    const callback_extra = try transformer.ast.addExtras(&.{ none, @backingInt(callback_params), @backingInt(callback_body), 0, none });
    const callback = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = callback_extra },
    });
    try transformer.bindGeneratedState(owner_scope, owner_scope, callback, state_parameter, 0, &.{}, &.{}, .EMPTY);

    const id_raw = transformer.getSymbolIdAt(binding) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const editor = if (transformer.semantic_editor) |*value| value else return error.TestUnexpectedResult;
    const id: @import("../semantic/symbol.zig").SymbolId = @fromBackingInt(@intCast(id_raw));
    const callback_scope_raw = editor.scope_owner_map.get(@backingInt(callback)).?;
    for (transformer.generator_state_temp_refs.items) |pending| {
        try std.testing.expectEqual(@as(?u32, id_raw), transformer.getSymbolIdAt(pending.reference));
        const reference_record = (try editor.referenceForNode(pending.reference)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(id, reference_record.symbol_id);
        try std.testing.expectEqual(callback_scope_raw, @backingInt(reference_record.scope_id));
    }
    try std.testing.expectEqual(@as(usize, source_symbol_count + 3), editor.symbols.items.len);
}

test "#4819 generator state-machine keeps late using temps for exact final naming" {
    const source =
        \\function* gen(sourceValue) {
        \\  for (using resource of sourceValue) {
        \\    yield resource;
        \\  }
        \\}
    ;
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

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
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
    try std.testing.expect(!root.isNone());

    var late_temps: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != .standalone_temp_binding or
            !std.mem.startsWith(u8, symbol.synthetic_name, "_using")) continue;
        late_temps += 1;
        if (transformer.block_rename_map) |*renames|
            try std.testing.expect(renames.get(@intCast(raw_id)) == null);
    }
    try std.testing.expect(late_temps > 0);
}

fn expectForAwaitSyntheticCoverage(source: []const u8, target: TransformOptions.compat.ESTarget, disable_top_level_await: bool) !void {
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

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(target),
        .emit_runtime_helper_imports = true,
    });
    if (disable_top_level_await) {
        // Isolate for-await's module-scope symbols from the separate TLA IIFE
        // producer, which owns its own generated promise binding.
        transformer.options.unsupported.top_level_await = false;
    }
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const coverage = @import("symbol_coverage.zig");
    var report = try coverage.checkStrict(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        &transformer.synthetic_idents.?,
        &analyzer.unresolved_references,
    );
    defer report.deinit(allocator);

    var marked_count: usize = 0;
    for (report.findings.items) |finding| {
        if (!finding.marked_synthetic) continue;
        marked_count += 1;
        if (finding.status != .bound) {
            if (finding.symbol_id) |symbol_id| {
                const symbol = edited.symbols.items[symbol_id];
                std.debug.print("non-bound synthetic finding: name={s} finding={any} kind={s} storage_scope_kind={s} expected_scope_kind={s}\n", .{
                    finding.name,
                    finding,
                    @tagName(symbol.kind),
                    @tagName(edited.scopes[symbol.scope_id.toIndex()].kind),
                    if (finding.expected_scope_id) |scope_id| @tagName(edited.scopes[scope_id].kind) else "unknown",
                });
            } else {
                std.debug.print("non-bound synthetic finding has no SymbolId: name={s} finding={any}\n", .{ finding.name, finding });
            }
        }
        try std.testing.expectEqual(coverage.StrictStatus.bound, finding.status);
    }
    try std.testing.expect(marked_count > 0);
}

test "#4819 for-await lowering registers every generated temp reference" {
    const source =
        \\const _a=1,_b=2,_step=3,_ret=4,_errObj=5,_err=6;
        \\async function drain(source) {
        \\  outer: for await (const item of source) {
        \\    try {
        \\      if (item === null) continue outer;
        \\      for await (const inner of source) {
        \\        try { if (inner === item) break; }
        \\        catch (_err2) { throw _err2; }
        \\      }
        \\    } catch (_outerErr) { if (_outerErr) break outer; }
        \\  }
        \\}
        \\top: for await (const item of input) { if (item) break top; }
    ;
    try expectForAwaitSyntheticCoverage(source, .es2017, true);
}

test "#4819 async-generator for-await temps keep their inner generator scope" {
    const source =
        \\const _a=1,_b=2,_step=3,_ret=4,_errObj=5,_err=6;
        \\async function* drain(source) {
        \\  outer: for await (const item of source) {
        \\    try {
        \\      if (item === null) continue outer;
        \\      inner: for await (const value of source) {
        \\        try { if (value === item) break inner; yield await value; }
        \\        catch (_err2) { yield _err2; }
        \\        finally { void item; }
        \\      }
        \\    } catch (_outerErr) { yield _outerErr; }
        \\    finally { void item; }
        \\  }
        \\}
    ;
    try expectForAwaitSyntheticCoverage(source, .es2017, false);
}

test "#4819 async-generator for-await temps survive ES5 state-machine lowering" {
    const source =
        \\const _a=1,_b=2,_step=3,_ret=4,_errObj=5,_err=6;
        \\async function* drain(source) {
        \\  outer: for await (const item of source) {
        \\    try {
        \\      if (item === null) continue outer;
        \\      inner: for await (const value of source) {
        \\        try { if (value === item) break inner; yield await value; }
        \\        catch (_err2) { yield _err2; }
        \\        finally { void item; }
        \\      }
        \\    } catch (_outerErr) { yield _outerErr; }
        \\    finally { void item; }
        \\  }
        \\}
    ;
    try expectForAwaitSyntheticCoverage(source, .es5, false);
}

test "#4819 nested async-generator temps keep their inner identity" {
    // Lower the outer for-in first so its state-machine temps are live when the nested async generator is lowered.
    const source =
        \\function* outer(source) {
        \\  for (const key in source) { yield key; }
        \\  async function* inner() {
        \\    for await (const value of source) { yield await value; }
        \\  }
        \\  yield inner;
        \\}
    ;
    try expectForAwaitSyntheticCoverage(source, .es5, true);
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
    // State-machine lowering flattens the temporary for-await wrapper block
    // into switch operations. The source loop scope therefore attaches
    // directly to the emitted generator callback, which remains nested in the
    // original async function scope.
    const wrapper_function = edited.scopes[original_header_scope.toIndex()].parent;
    try std.testing.expect(!wrapper_function.isNone());
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper_function.toIndex()].kind);
    try std.testing.expectEqual(source_function, edited.scopes[wrapper_function.toIndex()].parent);
    var live_owners: usize = 0;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        if (owner.value_ptr.* != @backingInt(wrapper_function)) continue;
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, owner.key_ptr.*) != null);
        const function = transformer.ast.nodes.items[owner.key_ptr.*];
        try std.testing.expectEqual(ast_mod.Node.Tag.function_expression, function.tag);
        try std.testing.expect(transformer.readU32(function.data.extra, ast_mod.FunctionExtra.flags) & ast_mod.FunctionFlags.is_generator != 0);
        live_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live_owners);
}
