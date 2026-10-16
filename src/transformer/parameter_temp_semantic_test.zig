const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const es_helpers = @import("es_helpers.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ESTarget = @import("compat.zig").ESTarget;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ScopeKind = @import("../semantic/scope.zig").ScopeKind;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;

fn checkParameterTempScopeImpl(source: []const u8, target: ESTarget, native_defaults: bool, expect_direct_reservation: ?bool) !void {
    try checkParameterTempScopeImplWithOutputScope(source, target, native_defaults, expect_direct_reservation, true);
}

fn checkParameterTempScopeImplWithOutputScope(
    source: []const u8,
    target: ESTarget,
    native_defaults: bool,
    expect_direct_reservation: ?bool,
    verify_output_scope: bool,
) !void {
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

    var function_scope: ?u32 = null;
    var parameter_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        const node = parser.ast.nodes.items[owner.key_ptr.*];
        if (node.tag != .method_definition and node.tag != .function_declaration and
            node.tag != .function_expression and node.tag != .arrow_function_expression) continue;
        if (parser.ast.functionParamsList(node).len == 0) continue;
        try std.testing.expect(function_scope == null);
        function_scope = owner.value_ptr.*;
        const params_slot = if (node.tag == .arrow_function_expression)
            @import("../parser/ast.zig").ArrowExtra.params
        else
            1;
        const params = parser.ast.readExtraNode(node.data.extra, params_slot);
        parameter_scope = analyzer.scope_owner_map.get(@intFromEnum(params));
    }
    // A retained default value is evaluated in its parameter environment, so
    // its temp references belong to the parameter scope (#5652). A lowered
    // default moves into the function body.
    const reference_scope = if (native_defaults)
        parameter_scope orelse return error.TestUnexpectedResult
    else
        function_scope orelse return error.TestUnexpectedResult;
    const expected_scope = if (native_defaults)
        analyzer.scope_owner_map.get(@intCast(parser.ast.nodes.items.len - 1)) orelse return error.TestUnexpectedResult
    else
        reference_scope;
    const original_symbol_count = analyzer.symbols.items.len;

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
    if (expect_direct_reservation) |expected_direct_reservation| {
        const editor = transformer.semantic_editor orelse return error.MissingSemanticEditor;
        var reserved = false;
        var ids = transformer.synthetic_temp_symbol_ids.valueIterator();
        while (ids.next()) |raw_id| {
            if (raw_id.* >= editor.symbols.items.len) continue;
            const symbol = editor.symbols.items[raw_id.*];
            if (symbol.kind == .variable_var and std.mem.eql(u8, symbol.synthetic_name, "_a") and
                @intFromEnum(symbol.scope_id) == reference_scope)
            {
                reserved = true;
                break;
            }
        }
        try std.testing.expectEqual(expected_direct_reservation, reserved);
    }
    const edited = (try transformer.finishSemanticEdit()).?;

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var temp_count: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind != .variable_var or !std.mem.eql(u8, symbol.synthetic_name, "_a")) continue;
        temp_count += 1;
        if (verify_output_scope) {
            try std.testing.expectEqual(expected_scope, @intFromEnum(symbol.scope_id));
            try std.testing.expectEqual(@as(u32, @intCast(symbol_index)), edited.scope_maps[expected_scope].get("_a").?);
        } else {
            try std.testing.expect(@intFromEnum(symbol.scope_id) < edited.scope_maps.len);
        }

        var bindings: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index))) bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);

        var refs: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != symbol_index or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@intFromEnum(ref.node_index)));
            try std.testing.expectEqual(reference_scope, @intFromEnum(ref.scope_id));
            try std.testing.expect(ref.flags.read or ref.flags.write);
            refs += 1;
        }
        try std.testing.expect(refs > 0);
        try std.testing.expectEqual(@as(u32, @intCast(refs)), symbol.reference_count);
    }
    try std.testing.expectEqual(@as(usize, 1), temp_count);
}

fn checkParameterTempScope(source: []const u8, target: ESTarget, native_defaults: bool) !void {
    return checkParameterTempScopeImpl(source, target, native_defaults, null);
}

fn expectArrowParameterTempDirectReservation(source: []const u8, target: ESTarget, expected: bool) !void {
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

    var arrow_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const node = parser.ast.nodes.items[entry.key_ptr.*];
        if (node.tag != .arrow_function_expression or parser.ast.functionParamsList(node).len == 0) continue;
        try std.testing.expect(arrow_scope == null);
        arrow_scope = entry.value_ptr.*;
    }
    const expected_scope = arrow_scope orelse return error.MissingArrowScope;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(target),
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

    const editor = transformer.semantic_editor orelse return error.MissingSemanticEditor;
    var reserved = false;
    var ids = transformer.synthetic_temp_symbol_ids.valueIterator();
    while (ids.next()) |raw_id| {
        if (raw_id.* >= editor.symbols.items.len) continue;
        const symbol = editor.symbols.items[raw_id.*];
        if (symbol.kind == .variable_var and std.mem.eql(u8, symbol.synthetic_name, "_a") and
            @intFromEnum(symbol.scope_id) == expected_scope)
        {
            reserved = true;
            break;
        }
    }
    try std.testing.expectEqual(expected, reserved);
}

test "#4819 parameter optional-chain temp uses exact emitted storage scope" {
    const fixtures = [_][]const u8{
        "function get(){return {value:5}} class C{constructor(value=get()?.value){this.value=value}} new C();",
        "function get(){return {value:5}} class C{method(value=get()?.value){return value}} new C().method();",
        "function get(){return {value:5}} class C{set value(input=get()?.value){this.saved=input}} new C().value=1;",
        "function get(){return {value:5}} class C{async method(value=get()?.value){return value}} new C().method();",
        "function get(){return {value:5}} class C{*method(value=get()?.value){yield value}} new C().method().next();",
        "function get(){return {value:5}} class C{async *method(value=get()?.value){yield value}} new C().method().next();",
        "function get(){return {value:5}} function* run(value=get()?.value){yield value} run().next();",
        "function get(){return {value:5}} async function run(value=get()?.value){return value} run();",
        "function get(){return {value:5}} async function* run(value=get()?.value){yield value} run().next();",
        "function get(){return {value:5}} async function* run(value=get()?.value){for await(const item of [1]) yield value+item} run().next();",
    };
    for (fixtures, 0..) |source, index| {
        const expect_direct = index < 3 or index == 7;
        try checkParameterTempScopeImpl(source, .es5, false, expect_direct);
    }
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} async function run(value=get()?.value){return value} run();",
        .es2016,
        true,
        false,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} async function* run(value=get()?.value){yield value} run().next();",
        .es2017,
        true,
        false,
    );
}

test "#4819 lowered synchronous parameter temp reserves its body SymbolId at creation" {
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} function read(value=get()?.value){return value} read();",
        .es5,
        false,
        true,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} class C{method(value=get()?.value){return value}} new C().method();",
        .es5,
        false,
        true,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} const read=function(value=get()?.value){return value}; read();",
        .es5,
        false,
        true,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} const read=(value=get()?.value)=>value; read();",
        .es5,
        false,
        true,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} const read=async (value=get()?.value)=>{await Promise.resolve();return value}; read();",
        .es5,
        false,
        true,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} async function read(value=get()?.value){await Promise.resolve();return value} read();",
        .es5,
        false,
        true,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} const read=async function(value=get()?.value){await Promise.resolve();return value}; read();",
        .es5,
        false,
        true,
    );
}

test "#4819 parameter eval keeps its output temp out of the function body scope" {
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} const read=(value=get()?.value)=>value; read();",
        .es2015,
        true,
        false,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} function read(value=(eval('0'),get()?.value)){return value} read();",
        .es5,
        true,
        false,
    );
    try checkParameterTempScopeImpl(
        "function get(){return {value:5}} const read=(value=(eval('0'),get()?.value))=>value; read();",
        .es5,
        true,
        false,
    );
    try checkParameterTempScopeImplWithOutputScope(
        "function get(){return {value:5}} async function read(value=(eval('0'),get()?.value)){return value} read();",
        .es5,
        true,
        false,
        false,
    );
    try checkParameterTempScopeImplWithOutputScope(
        "function get(){return {value:5}} async function read(value=get()?.value){eval('0');return value} read();",
        .es5,
        true,
        false,
        false,
    );
}

test "#4819 unsafe arrow parameter temp owners stay deferred" {
    try expectArrowParameterTempDirectReservation(
        "function get(){return {value:5}} const read=async (value=get()?.value)=>{await Promise.resolve();return value}; read();",
        .es5,
        true,
    );
    try expectArrowParameterTempDirectReservation(
        "function get(){return {value:5}} const read=async (value=(eval('0'),get()?.value))=>value; read();",
        .es5,
        false,
    );
    try expectArrowParameterTempDirectReservation(
        "function get(){return {value:5}} const read=async (value=get()?.value)=>{eval('0');return value}; read();",
        .es5,
        false,
    );
    try expectArrowParameterTempDirectReservation(
        "function get(){return {value:5}} const read=(value=(eval('0'),get()?.value))=>value; read();",
        .es5,
        false,
    );
    try expectArrowParameterTempDirectReservation(
        "function get(){return {value:5}} const read=(value=get()?.value)=>{eval('0');return value}; read();",
        .es5,
        false,
    );
    try expectArrowParameterTempDirectReservation(
        "function get(){return {value:5}} const read=(value=get()?.value)=>value; read();",
        .es2015,
        false,
    );
}

test "#4819 arrow temp defers when its parameter owner does not match its scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function get(){return {value:5}} const read=async (value=get()?.value)=>value; function other(input){return input}");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var arrow_owner: ?NodeIndex = null;
    var arrow_scope: ?u32 = null;
    var arrow_params: ?NodeIndex = null;
    var parameter_scope: ?u32 = null;
    var unrelated_params: ?NodeIndex = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: NodeIndex = @enumFromInt(entry.key_ptr.*);
        const node = parser.ast.getNode(owner);
        if (node.tag == .arrow_function_expression and parser.ast.functionParamsList(node).len > 0) {
            arrow_owner = owner;
            arrow_scope = entry.value_ptr.*;
            arrow_params = parser.ast.readExtraNode(node.data.extra, @import("../parser/ast.zig").ArrowExtra.params);
            parameter_scope = analyzer.scope_owner_map.get(@intFromEnum(arrow_params.?));
        } else if (node.tag == .function_declaration and parser.ast.functionParamsList(node).len > 0) {
            unrelated_params = parser.ast.readExtraNode(node.data.extra, 1);
        }
    }
    const owner: NodeIndex = arrow_owner orelse return error.MissingArrowOwner;
    const body_scope: u32 = arrow_scope orelse return error.MissingArrowScope;
    const params: NodeIndex = arrow_params orelse return error.MissingArrowParams;
    const param_scope: u32 = parameter_scope orelse return error.MissingParameterScope;
    const other_params: NodeIndex = unrelated_params orelse return error.MissingUnrelatedParams;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.state_machine_depth = 1;
    transformer.lowered_parameter_temp_output_owner = owner;

    transformer.ast.extra_data.items[parser.ast.getNode(owner).data.extra + @import("../parser/ast.zig").ArrowExtra.params] = @intFromEnum(other_params);
    const name = try transformer.ast.addString("_a");
    const reference = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, name);
    try transformer.trackSyntheticTempReferenceInScope(
        name,
        parser.ast.getNode(params).span,
        reference,
        @enumFromInt(body_scope),
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(usize, 1), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(param_scope, @intFromEnum(analyzer.scopes.items[body_scope].parent));

    transformer.ast.extra_data.items[parser.ast.getNode(owner).data.extra + @import("../parser/ast.zig").ArrowExtra.params] = @intFromEnum(params);
    analyzer.scopes.items[body_scope].parent = .none;
    const bad_parent_name = try transformer.ast.addString("_b");
    const bad_parent_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, bad_parent_name);
    try transformer.trackSyntheticTempReferenceInScope(
        bad_parent_name,
        parser.ast.getNode(other_params).span,
        bad_parent_ref,
        @enumFromInt(body_scope),
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(usize, 2), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
}

test "#4819 async function temp defers when its parameter owner or wrapper parent does not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function get(input){return {value:5}} async function read(value=get()?.value){return value}");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var async_owner: ?NodeIndex = null;
    var async_scope: ?u32 = null;
    var async_params: ?NodeIndex = null;
    var async_parameter_scope: ?u32 = null;
    var other_params: ?NodeIndex = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: NodeIndex = @enumFromInt(entry.key_ptr.*);
        const node = parser.ast.getNode(owner);
        if (node.tag != .function_declaration or parser.ast.functionParamsList(node).len == 0) continue;
        const flags = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").FunctionExtra.flags];
        if ((flags & @import("../parser/ast.zig").FunctionFlags.is_async) != 0) {
            async_owner = owner;
            async_scope = entry.value_ptr.*;
            async_params = parser.ast.readExtraNode(node.data.extra, @import("../parser/ast.zig").FunctionExtra.params);
            async_parameter_scope = analyzer.scope_owner_map.get(@intFromEnum(async_params.?));
        } else {
            other_params = parser.ast.readExtraNode(node.data.extra, @import("../parser/ast.zig").FunctionExtra.params);
        }
    }
    const owner = async_owner orelse return error.MissingAsyncFunctionOwner;
    const wrapper_scope = async_scope orelse return error.MissingAsyncFunctionScope;
    const params = async_params orelse return error.MissingAsyncFunctionParams;
    const parameter_scope = async_parameter_scope orelse return error.MissingAsyncParameterScope;
    const unrelated_params = other_params orelse return error.MissingUnrelatedParams;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.state_machine_depth = 1;
    transformer.lowered_parameter_temp_output_owner = owner;

    const params_extra = parser.ast.getNode(owner).data.extra + @import("../parser/ast.zig").FunctionExtra.params;
    try std.testing.expectEqual(parameter_scope, @intFromEnum(analyzer.scopes.items[wrapper_scope].parent));
    transformer.ast.extra_data.items[params_extra] = @intFromEnum(unrelated_params);
    const wrong_owner_name = try transformer.ast.addString("_a");
    const wrong_owner_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, wrong_owner_name);
    try transformer.trackSyntheticTempReferenceInScope(
        wrong_owner_name,
        parser.ast.getNode(params).span,
        wrong_owner_ref,
        @enumFromInt(wrapper_scope),
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(usize, 1), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());

    transformer.ast.extra_data.items[params_extra] = @intFromEnum(params);
    analyzer.scopes.items[wrapper_scope].parent = .none;
    if (transformer.semantic_editor) |*editor| editor.scopes.items[wrapper_scope].parent = .none;
    const wrong_parent_name = try transformer.ast.addString("_b");
    const wrong_parent_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, wrong_parent_name);
    try transformer.trackSyntheticTempReferenceInScope(
        wrong_parent_name,
        parser.ast.getNode(params).span,
        wrong_parent_ref,
        @enumFromInt(wrapper_scope),
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(usize, 2), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
    try std.testing.expectEqual(ScopeId.none, analyzer.scopes.items[wrapper_scope].parent);

    analyzer.scopes.items[wrapper_scope].parent = @enumFromInt(parameter_scope);
    analyzer.scopes.items[wrapper_scope].kind = .block;
    if (transformer.semantic_editor) |*editor| {
        editor.scopes.items[wrapper_scope].parent = @enumFromInt(parameter_scope);
        editor.scopes.items[wrapper_scope].kind = .block;
    }
    const wrong_kind_name = try transformer.ast.addString("_c");
    const wrong_kind_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, wrong_kind_name);
    try transformer.trackSyntheticTempReferenceInScope(
        wrong_kind_name,
        parser.ast.getNode(params).span,
        wrong_kind_ref,
        @enumFromInt(wrapper_scope),
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(usize, 3), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
}

test "#4819 parameter temp defers when its output owner is misparented or ambiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function get(){return {value:5}} function read(value=get()?.value){return value}");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var function_scope: ?u32 = null;
    var parameter_scope: ?u32 = null;
    var parameter_node: ?NodeIndex = null;
    var unrelated_function: ?NodeIndex = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: NodeIndex = @enumFromInt(entry.key_ptr.*);
        const node = parser.ast.getNode(owner);
        if (node.tag == .function_declaration and parser.ast.functionParamsList(node).len > 0) {
            function_scope = entry.value_ptr.*;
            parameter_node = parser.ast.readExtraNode(node.data.extra, 1);
            parameter_scope = analyzer.scope_owner_map.get(@intFromEnum(parameter_node.?));
        } else if (node.tag == .function_declaration) {
            unrelated_function = owner;
        }
    }
    const body_scope: u32 = function_scope orelse return error.MissingFunctionScope;
    const param_scope: u32 = parameter_scope orelse return error.MissingParameterScope;
    const params: NodeIndex = parameter_node orelse return error.MissingParameterNode;
    const other_function: NodeIndex = unrelated_function orelse return error.MissingUnrelatedFunction;
    const other_extra: usize = @intCast(parser.ast.getNode(other_function).data.extra);
    const original_other_params = parser.ast.readExtraNode(parser.ast.getNode(other_function).data.extra, 1);
    const original_body_kind = analyzer.scopes.items[body_scope].kind;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
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

    const original_parent = analyzer.scopes.items[body_scope].parent;
    analyzer.scopes.items[body_scope].parent = .none;
    const first_name = try transformer.ast.addString("_a");
    const first_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, first_name);
    try transformer.trackSyntheticTempReferenceInScope(first_name, parser.ast.getNode(params).span, first_ref, @enumFromInt(param_scope), .{ .read = true });
    try std.testing.expectEqual(@as(usize, 1), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());

    analyzer.scopes.items[body_scope].parent = original_parent;
    if (transformer.semantic_editor) |*editor| editor.scopes.items[body_scope].parent = original_parent;
    transformer.ast.extra_data.items[other_extra + 1] = @intFromEnum(params);
    const second_name = try transformer.ast.addString("_b");
    const second_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, second_name);
    try transformer.trackSyntheticTempReferenceInScope(second_name, parser.ast.getNode(params).span, second_ref, @enumFromInt(param_scope), .{ .read = true });
    try std.testing.expectEqual(@as(usize, 2), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());

    transformer.ast.extra_data.items[other_extra + 1] = @intFromEnum(original_other_params);
    analyzer.scopes.items[body_scope].kind = .block;
    if (transformer.semantic_editor) |*editor| editor.scopes.items[body_scope].kind = .block;
    const third_name = try transformer.ast.addString("_c");
    const third_ref = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, third_name);
    try transformer.trackSyntheticTempReferenceInScope(third_name, parser.ast.getNode(params).span, third_ref, @enumFromInt(param_scope), .{ .read = true });
    try std.testing.expectEqual(@as(usize, 3), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.synthetic_temp_symbol_ids.count());
    analyzer.scopes.items[body_scope].kind = original_body_kind;
    if (transformer.semantic_editor) |*editor| editor.scopes.items[body_scope].kind = original_body_kind;
}

test "#4819 nullish-assignment parameter temp uses exact emitted storage scope" {
    try checkParameterTempScope(
        "function get(){return {value:null}} function read(value=get().value ??=5){return value} read();",
        .es5,
        false,
    );
}

fn checkDestructuringParameterTempSymbols(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        switch (parser.ast.nodes.items[owner.key_ptr.*].tag) {
            .function_declaration, .function_expression, .function, .method_definition, .arrow_function_expression => function_scope = owner.value_ptr.*,
            else => {},
        }
    }
    const expected_function_scope = function_scope orelse return error.MissingFunctionScope;
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
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());

    var parameter_temps: usize = 0;
    var function_var_temps: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, symbol_index| {
        if (symbol.synthetic_name.len < 2 or symbol.synthetic_name[0] != '_' or symbol.synthetic_name[1] == '_') continue;
        if (symbol.kind == .parameter) {
            parameter_temps += 1;
            try std.testing.expectEqual(expected_function_scope, @intFromEnum(symbol.scope_id));
        } else if (symbol.kind == .variable_var and @intFromEnum(symbol.scope_id) == expected_function_scope) {
            function_var_temps += 1;
        } else if (symbol.kind == .variable_var) {
            try std.testing.expectEqual(expected_function_scope, @intFromEnum(symbol.scope_id));
        }

        var live_bindings: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index)))
                live_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), live_bindings);

        var live_references: u32 = 0;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != symbol_index or reference.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @intFromEnum(reference.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@intFromEnum(reference.node_index)]);
            try std.testing.expectEqual(expected_function_scope, @intFromEnum(reference.scope_id));
            try std.testing.expect(reference.flags.read or reference.flags.write);
            live_references += 1;
        }
        try std.testing.expectEqual(symbol.reference_count, live_references);
    }

    var exact_temp_ids = transformer.destructuring_temp_symbol_ids.iterator();
    var mapped_temp_count: usize = 0;
    while (exact_temp_ids.next()) |entry| {
        const raw_symbol_index = entry.value_ptr.*;
        const symbol_index: usize = @intCast(raw_symbol_index);
        try std.testing.expect(symbol_index >= original_symbol_count and symbol_index < edited.symbols.items.len);
        const symbol = edited.symbols.items[symbol_index];
        try std.testing.expect(symbol.kind == .parameter or symbol.kind == .variable_var);
        try std.testing.expectEqual(expected_function_scope, @intFromEnum(symbol.scope_id));

        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == raw_symbol_index) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        mapped_temp_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), parameter_temps);
    try std.testing.expect(function_var_temps > 0);
    try std.testing.expectEqual(parameter_temps + function_var_temps, mapped_temp_count);
}

fn expectRegisteredParameterTemp(
    transformer: *Transformer,
    binding: @import("../parser/ast.zig").NodeIndex,
    expected_scope: ScopeId,
    expected_kind: SymbolKind,
) !u32 {
    const raw_id = transformer.getSymbolIdAt(binding) orelse return error.MissingCreationSymbolId;
    const name_span = transformer.ast.getNode(binding).data.string_ref;
    try std.testing.expectEqual(raw_id, transformer.destructuring_temp_symbol_ids.get(name_span.start).?);

    const editor = transformer.semantic_editor orelse return error.MissingSemanticEditor;
    try std.testing.expect(raw_id < editor.symbols.items.len);
    const symbol = editor.symbols.items[raw_id];
    try std.testing.expectEqual(expected_kind, symbol.kind);
    try std.testing.expectEqual(expected_scope, symbol.scope_id);
    const emitted_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else transformer.ast.getText(symbol.name);
    try std.testing.expectEqual(@as(?usize, raw_id), editor.scope_maps.items[expected_scope.toIndex()].get(emitted_name));

    var live_uses: u32 = 0;
    for (editor.references.items) |reference| {
        if (@intFromEnum(reference.symbol_id) != raw_id or reference.flags.declare) continue;
        try std.testing.expect(!reference.node_index.isNone());
        try std.testing.expectEqual(expected_scope, reference.scope_id);
        try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(reference.node_index));
        try std.testing.expect(reference.flags.read or reference.flags.write);
        live_uses += 1;
    }
    try std.testing.expect(live_uses > 0);
    try std.testing.expectEqual(symbol.reference_count, live_uses);
    return raw_id;
}

fn lowerParameterPatternAndCheckCreation(
    source: []const u8,
    expect_array_read_binding: bool,
    reserve_ownerless_function_scope: bool,
) !void {
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
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_node: ?@import("../parser/ast.zig").NodeIndex = null;
    var function_scope: ?ScopeId = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        const node = parser.ast.nodes.items[owner.key_ptr.*];
        if (parser.ast.functionParamsList(node).len == 0) continue;
        function_node = @enumFromInt(owner.key_ptr.*);
        function_scope = @enumFromInt(owner.value_ptr.*);
        break;
    }
    const target_node = function_node orelse return error.MissingFunctionOwner;
    const source_scope = function_scope orelse return error.MissingFunctionScope;

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

    const output_scope = if (reserve_ownerless_function_scope) blk: {
        const parent = transformer.scopes[source_scope.toIndex()].parent;
        const reserved = try transformer.reserveGeneratedFunctionScope(parent);
        try std.testing.expect(reserved.toIndex() >= transformer.scopes.len);
        const editor = transformer.semantic_editor orelse return error.MissingSemanticEditor;
        try std.testing.expectEqual(ScopeKind.function, editor.scopes.items[reserved.toIndex()].kind);
        var output_has_owner = false;
        var scope_owners = editor.scope_owner_map.iterator();
        while (scope_owners.next()) |owner| {
            if (owner.value_ptr.* == @intFromEnum(reserved)) output_has_owner = true;
        }
        try std.testing.expect(!output_has_owner);
        break :blk reserved;
    } else source_scope;

    transformer.current_scope = output_scope;
    const function = transformer.ast.getNode(target_node);
    var lowered = try @import("es2015_params.zig").ES2015Params(Transformer).lowerParamsPass2(
        &transformer,
        transformer.ast.functionParamsList(function),
        function.span,
    );
    defer lowered.body_stmts.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), lowered.new_params.len);
    const parameter_binding: @import("../parser/ast.zig").NodeIndex = @enumFromInt(transformer.ast.extra_data.items[lowered.new_params.start]);
    const parameter_id = try expectRegisteredParameterTemp(&transformer, parameter_binding, output_scope, .parameter);

    var read_binding: ?@import("../parser/ast.zig").NodeIndex = null;
    if (expect_array_read_binding) {
        for (lowered.body_stmts.items) |statement_idx| {
            const statement = transformer.ast.getNode(statement_idx);
            if (statement.tag != .variable_declaration) continue;
            const list_start = transformer.ast.extra_data.items[statement.data.extra + 1];
            const list_len = transformer.ast.extra_data.items[statement.data.extra + 2];
            if (list_len == 0) continue;
            const first_declarator: @import("../parser/ast.zig").NodeIndex = @enumFromInt(transformer.ast.extra_data.items[list_start]);
            read_binding = transformer.ast.readExtraNode(transformer.ast.getNode(first_declarator).data.extra, 0);
            break;
        }
        const array_read = read_binding orelse return error.MissingArrayReadBinding;
        const read_id = try expectRegisteredParameterTemp(&transformer, array_read, output_scope, .variable_var);
        try std.testing.expect(read_id != parameter_id);
    }

    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
}

test "#4819 default object-pattern temp is registered before lowerParamsPass2 references" {
    try lowerParameterPatternAndCheckCreation(
        "function run({ first: { seed } } = {}) { return seed; }",
        false,
        false,
    );
}

test "#4819 default array-pattern parameter and read temps are registered at creation" {
    try lowerParameterPatternAndCheckCreation(
        "function run([{ first: { seed } } = {}] = []) { return seed; }",
        true,
        false,
    );
}

test "#4819 plain object-pattern parameter temp is registered at creation" {
    try lowerParameterPatternAndCheckCreation(
        "function run({ first: { seed } }) { return seed; }",
        false,
        false,
    );
}

test "#4819 plain array-pattern parameter and read temps are registered at creation" {
    try lowerParameterPatternAndCheckCreation(
        "function run([{ first: { seed } }]) { return seed; }",
        true,
        false,
    );
}

test "#4819 reserved generated constructor scope owns parameter temps before its AST owner" {
    try lowerParameterPatternAndCheckCreation(
        "class Host { constructor({ first: { seed } } = {}) { return seed; } }",
        false,
        true,
    );
}

fn checkStandaloneParameterTempNameMarking(source: []const u8, expected_late: bool) !void {
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

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
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
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var generated_temps: usize = 0;
    var late_generated_temps: usize = 0;
    var generated_parameter_temps: usize = 0;
    var late_parameter_temps: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind == .parameter and symbol.synthetic_name.len > 1 and symbol.synthetic_name[0] == '_') {
            generated_parameter_temps += 1;
            if (symbol.synthetic_kind == .standalone_temp_binding) {
                late_parameter_temps += 1;
                const raw_id: u32 = @intCast(symbol_index);
                try std.testing.expectEqual(
                    @as(?usize, symbol_index),
                    edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
                );
                var bindings: usize = 0;
                var references: usize = 0;
                for (transformer.ast.nodes.items, 0..) |node, raw_node| {
                    if (node.tag != .binding_identifier or raw_node >= edited.symbol_ids.len or edited.symbol_ids[raw_node] != raw_id) continue;
                    bindings += 1;
                }
                for (edited.references) |reference| {
                    if (@intFromEnum(reference.symbol_id) != raw_id or reference.flags.declare) continue;
                    try std.testing.expect(!reference.node_index.isNone());
                    try std.testing.expectEqual(@as(?u32, raw_id), edited.symbol_ids[@intFromEnum(reference.node_index)]);
                    try std.testing.expectEqual(symbol.scope_id, reference.scope_id);
                    references += 1;
                }
                try std.testing.expectEqual(@as(usize, 1), bindings);
                try std.testing.expect(references > 0);
            }
        }
        if (symbol.kind != .variable_var or symbol.synthetic_name.len == 0 or symbol.synthetic_name[0] != '_') continue;
        generated_temps += 1;
        if (symbol.synthetic_kind != .standalone_temp_binding) continue;
        late_generated_temps += 1;
        const raw_id: u32 = @intCast(symbol_index);
        try std.testing.expectEqual(@as(?usize, symbol_index), edited.scope_maps[@intFromEnum(symbol.scope_id)].get(symbol.synthetic_name));
        var bindings: usize = 0;
        var references: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw_node| {
            if (node.tag != .binding_identifier or raw_node >= edited.symbol_ids.len or edited.symbol_ids[raw_node] != raw_id) continue;
            bindings += 1;
        }
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != raw_id or reference.flags.declare) continue;
            try std.testing.expect(!reference.node_index.isNone());
            try std.testing.expectEqual(@as(?u32, raw_id), edited.symbol_ids[@intFromEnum(reference.node_index)]);
            references += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expect(references > 0);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_parameter_temps);
    try std.testing.expectEqual(@as(usize, @intFromBool(expected_late)), late_parameter_temps);
    try std.testing.expect(generated_temps > 0);
    try std.testing.expectEqual(expected_late, late_generated_temps > 0);
}

test "#4819 standalone parameter destructuring temps finalize from exact symbols unless dynamic lookup blocks it" {
    try checkStandaloneParameterTempNameMarking(
        "function run(_a, [{ first: { seed } }]) { return [_a, seed]; }",
        true,
    );
    try checkStandaloneParameterTempNameMarking(
        "function run([{ first: { seed } }]) { return seed; } function sibling() { eval('typeof _a'); }",
        false,
    );
}

fn lowerDestructuringParametersWithoutSemanticEditing(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var target_node: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (parser.ast.functionParamsList(node).len == 0) continue;
        target_node = @enumFromInt(raw);
        break;
    }
    const function_node = target_node orelse return error.MissingFunctionOwner;
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
    });
    try std.testing.expect(!transformer.semantic_edit_enabled);
    try std.testing.expect(transformer.current_scope.isNone());
    const function = transformer.ast.getNode(function_node);
    var lowered = try @import("es2015_params.zig").ES2015Params(Transformer).lowerParamsPass2(
        &transformer,
        transformer.ast.functionParamsList(function),
        function.span,
    );
    defer lowered.body_stmts.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), transformer.destructuring_temp_symbol_ids.count());
}

test "#4819 semantic-disabled low-level parameter lowering remains a no-op for temp ownership" {
    try lowerDestructuringParametersWithoutSemanticEditing(
        "function run({ first: { seed } } = {}) { return seed; }",
    );
    try lowerDestructuringParametersWithoutSemanticEditing(
        "function run([{ first: { seed } }]) { return seed; }",
    );
}

test "#4819 destructuring parameter temps stay in their emitted function scope" {
    const fixtures = [_][]const u8{
        "function run({ first: { seed } }) { return seed; }",
        "function run({ first: { seed } } = {}) { return seed; }",
        "function run([{ first: { seed } }]) { return seed; }",
        "function run([{ first: { seed } } = {}] = []) { return seed; }",
        "function run({ [key()]: { seed }, ...rest } = {}) { return [seed, rest]; }",
        "class Host { run({ first: { seed } }) { return seed; } }",
        "const run = ({ first: { seed } }) => seed;",
    };
    for (fixtures) |source| try checkDestructuringParameterTempSymbols(source);
}
