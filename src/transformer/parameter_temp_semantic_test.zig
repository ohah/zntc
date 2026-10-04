const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ast_walk = @import("../parser/ast_walk.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ESTarget = @import("compat.zig").ESTarget;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ScopeKind = @import("../semantic/scope.zig").ScopeKind;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;

fn checkParameterTempScope(source: []const u8, target: ESTarget, native_defaults: bool) !void {
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
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        const node = parser.ast.nodes.items[owner.key_ptr.*];
        if (node.tag != .method_definition and node.tag != .function_declaration) continue;
        if (parser.ast.functionParamsList(node).len == 0) continue;
        try std.testing.expect(function_scope == null);
        function_scope = owner.value_ptr.*;
    }
    const reference_scope = function_scope orelse return error.TestUnexpectedResult;
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
    const edited = (try transformer.finishSemanticEdit()).?;

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var temp_count: usize = 0;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, symbol_index| {
        if (symbol.kind != .variable_var or !std.mem.eql(u8, symbol.synthetic_name, "_a")) continue;
        temp_count += 1;
        try std.testing.expectEqual(expected_scope, @intFromEnum(symbol.scope_id));
        try std.testing.expectEqual(@as(u32, @intCast(symbol_index)), edited.scope_maps[expected_scope].get("_a").?);

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
    for (fixtures) |source| try checkParameterTempScope(source, .es5, false);
    try checkParameterTempScope(
        "function get(){return {value:5}} async function run(value=get()?.value){return value} run();",
        .es2016,
        true,
    );
    try checkParameterTempScope(
        "function get(){return {value:5}} async function* run(value=get()?.value){yield value} run().next();",
        .es2017,
        true,
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
