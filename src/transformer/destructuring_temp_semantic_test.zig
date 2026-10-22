const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast_walk = @import("../parser/ast_walk.zig");
const ESTarget = @import("compat.zig").ESTarget;
const es_helpers = @import("es_helpers.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;

fn symbolVisibleFrom(scopes: []const @import("../semantic/scope.zig").Scope, declared: ScopeId, use: ScopeId) bool {
    var cursor = use;
    var remaining = scopes.len + 1;
    while (!cursor.isNone() and @backingInt(cursor) < scopes.len and remaining > 0) : (remaining -= 1) {
        if (cursor == declared) return true;
        cursor = scopes[@backingInt(cursor)].parent;
    }
    return false;
}

fn collectGeneratedTempSymbolIds(allocator: std.mem.Allocator, transformer: anytype, edited: anytype, original_symbol_count: usize) !std.ArrayList(u32) {
    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (raw_id < original_symbol_count or symbol.synthetic_name.len == 0 or symbol.synthetic_name[0] != '_') continue;
        switch (symbol.kind) {
            .variable_var, .variable_let, .variable_const => {},
            else => continue,
        }
        try ids.append(allocator, @intCast(raw_id));
    }
    _ = transformer;
    return ids;
}

fn checkDestructuringTempIdentityGraph(allocator: std.mem.Allocator, source: []const u8) !void {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var temp_ids = try collectGeneratedTempSymbolIds(allocator, &transformer, edited, original_symbol_count);
    defer temp_ids.deinit(allocator);
    try std.testing.expect(temp_ids.items.len > 0);
    var standalone_temp_count: usize = 0;
    for (temp_ids.items) |raw_id| {
        const id: usize = raw_id;
        try std.testing.expect(id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        if (std.mem.startsWith(u8, symbol.synthetic_name, "__")) continue;
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqual(.variable_var, symbol.kind);
        try std.testing.expectEqual(.function, edited.scopes[@backingInt(symbol.scope_id)].kind);
        switch (symbol.synthetic_kind orelse return error.MissingDestructuringTempNameMark) {
            .standalone_temp_binding => {
                standalone_temp_count += 1;
            },
            .for_of_step_binding => {},
            else => return error.UnexpectedDestructuringTempNameMark,
        }
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[@backingInt(symbol.scope_id)].get(symbol.synthetic_name));

        var binding_count: usize = 0;
        for (reachable) |raw_node| {
            if (transformer.ast.nodes.items[raw_node].tag != .binding_identifier) continue;
            if (raw_node < edited.symbol_ids.len and edited.symbol_ids[raw_node] == raw_id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var reference_count: u32 = 0;
        var read_count: u32 = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(reference.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, raw_id), transformer.getSymbolIdAt(reference.node_index));
            const reference_node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(symbol.name.start, reference_node.data.string_ref.start);
            try std.testing.expectEqual(symbol.name.end, reference_node.data.string_ref.end);
            try std.testing.expect(reference.flags.read or reference.flags.write);
            try std.testing.expect(symbolVisibleFrom(edited.scopes, symbol.scope_id, reference.scope_id));
            if (reference.flags.read) read_count += 1;
            reference_count += 1;
        }
        try std.testing.expect(read_count > 0);
        try std.testing.expectEqual(symbol.reference_count, reference_count);
    }
    try std.testing.expect(standalone_temp_count > 0);
}

test "#4819 destructuring temps keep exact producer IDs across hostile patterns" {
    const cases = [_][]const u8{
        "function run(input) { const { first: { seed } } = input; return seed; }",
        "function run(input) { let [[head, { value = 2 }], ...tail] = input; return [head, value, tail]; }",
        "function run(input) { let _a = 77, result; ({ part: { value: result = _a } = {} } = input); return result; }",
        "function run(input) { let _a = 88, value = 0; return ([[value] = []] = input); }",
        "function run(input, key) { const { [key]: value, ...rest } = input; return [value, rest]; }",
        "function run(input, key) { let value; ({ [key]: { value = 1 } = {} } = input); return value; }",
        "function run(items) { const out = []; for (const { item: { value = 0 }, ...rest } of items) out.push(() => [value, rest]); return out; }",
        "function run(source) { const out = []; for (const { x } in source) out.push(() => x); return out; }",
        "function run({ rows: [{ name = 'x' } = []] = [] } = {}) { return name; }",
        "function run([{ [key()]: value = 1 } = []] = []) { return value; }",
    };

    try std.testing.expectEqual(@as(usize, 10), cases.len);
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try checkDestructuringTempIdentityGraph(arena.allocator(), source);
    }
}

test "#4819 assignment destructuring temp refs receive their producer SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run() { let target = 0; ({ target } = input); }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const source_symbol_count = analyzer.symbols.items.len;

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration)
            function_scope = entry.value_ptr.*;
    }
    const owner = function_scope orelse return error.MissingFunctionScope;
    var assignment: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .assignment_expression) continue;
        if (parser.ast.getNode(node.data.binary.left).tag != .object_assignment_target) continue;
        assignment = @fromBackingInt(@intCast(raw));
        break;
    }
    const assignment_idx = assignment orelse return error.MissingDestructuringAssignment;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
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
    transformer.current_scope = @fromBackingInt(@intCast(owner));

    const lowerer = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
    _ = try lowerer.lowerDestructuringAssignment(&transformer, parser.ast.getNode(assignment_idx), false);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    var name_span: ?@import("../lexer/token.zig").Span = null;
    var span_it = transformer.temp_span_by_counter.valueIterator();
    while (span_it.next()) |span| name_span = span.*;
    const temp_span = name_span orelse return error.MissingDestructuringTemp;
    const reserved_symbol_id = transformer.lookupSyntheticTempSymbol(temp_span, transformer.current_scope) orelse
        return error.MissingDestructuringTempSymbol;
    var temp_counter: ?u32 = null;
    var temp_ids = transformer.temp_symbol_ids_by_counter.iterator();
    while (temp_ids.next()) |entry| {
        if (entry.value_ptr.* == @backingInt(reserved_symbol_id)) temp_counter = entry.key_ptr.*;
    }
    const counter = temp_counter orelse return error.MissingDestructuringTempCounter;
    const temp_producer_id = transformer.temp_producer_id_by_counter.get(counter) orelse
        return error.MissingDestructuringTempProducerId;
    const id = reserved_symbol_id;
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    try std.testing.expectEqual(source_symbol_count + 1, editor.symbols.items.len);
    var reads: usize = 0;
    var writes: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        if (node.data.string_ref.start != temp_span.start or node.data.string_ref.end != temp_span.end) continue;
        try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))));
        const reference = (try editor.referenceForNode(@fromBackingInt(@intCast(raw)))) orelse return error.MissingDestructuringTempReference;
        try std.testing.expectEqual(id, reference.symbol_id);
        try std.testing.expectEqual(@as(@import("../semantic/scope.zig").ScopeId, @fromBackingInt(@intCast(owner))), reference.scope_id);
        if (reference.flags.read) reads += 1;
        if (reference.flags.write) writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expectEqual(@as(usize, 1), writes);

    const binding = try es_helpers.makeSyntheticBinding(&transformer, temp_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        binding,
        temp_span,
        parser.ast.getNode(assignment_idx).span,
        @fromBackingInt(@intCast(owner)),
        id,
        temp_producer_id,
    );
    try std.testing.expectEqual(@as(?u32, @backingInt(id)), transformer.getSymbolIdAt(binding));
    try std.testing.expectEqual(source_symbol_count + 1, editor.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

fn checkArrayAssignmentValueTempProducerIdentity(allocator: std.mem.Allocator, source: []const u8) !void {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope_raw: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration) {
            function_scope_raw = entry.value_ptr.*;
            break;
        }
    }
    const function_scope = function_scope_raw orelse return error.MissingFunctionScope;
    const var_scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(@intCast(function_scope));

    var assignment: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .assignment_expression) continue;
        const target = parser.ast.getNode(node.data.binary.left);
        if (target.tag != .array_assignment_target and target.tag != .array_pattern) continue;
        assignment = @fromBackingInt(@intCast(raw));
        break;
    }
    const assignment_idx = assignment orelse return error.MissingArrayAssignment;
    const assignment_span = parser.ast.getNode(assignment_idx).span;
    const assignment_target = parser.ast.getNode(assignment_idx).data.binary.left;
    const TargetReferenceScope = struct {
        analyzer: *SemanticAnalyzer,
        scope: ?@import("../semantic/scope.zig").ScopeId = null,

        fn visit(ctx: *@This(), idx: @import("../parser/ast.zig").NodeIndex, node: @import("../parser/ast.zig").Node) ast_walk.WalkAction {
            if (node.tag == .assignment_target_identifier or node.tag == .identifier_reference) {
                for (ctx.analyzer.references.items) |reference| {
                    if (reference.node_index != idx) continue;
                    ctx.scope = reference.scope_id;
                    return .stop;
                }
            }
            return .descend;
        }
    };
    var target_scope_search = TargetReferenceScope{ .analyzer = &analyzer };
    try ast_walk.walkPreorderIterative(allocator, &parser.ast, assignment_target, &target_scope_search, TargetReferenceScope.visit);
    const expected_scope = target_scope_search.scope orelse return error.MissingArrayTargetReferenceScope;

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
    transformer.current_scope = expected_scope;

    const lowerer = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
    _ = try lowerer.lowerDestructuringAssignment(&transformer, parser.ast.getNode(assignment_idx), true);

    var value_temp_counter: ?u32 = null;
    var temp_ids = transformer.temp_symbol_ids_by_counter.iterator();
    while (temp_ids.next()) |entry| {
        const counter = entry.key_ptr.*;
        if (value_temp_counter == null or counter < value_temp_counter.?) value_temp_counter = counter;
    }
    const counter = value_temp_counter orelse return error.MissingValueTempSymbolId;
    const value_temp_span = transformer.temp_span_by_counter.get(counter) orelse return error.MissingValueTempSpan;
    const value_temp_id = transformer.temp_symbol_ids_by_counter.get(counter) orelse return error.MissingValueTempSymbolId;
    const temp_producer_id = transformer.temp_producer_id_by_counter.get(counter) orelse
        return error.MissingValueTempProducerId;
    try std.testing.expect(transformer.lookupSyntheticTempSymbol(value_temp_span, expected_scope) == null);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const expected_var_scope = transformer.nearestVarScope(expected_scope);
    try std.testing.expectEqual(var_scope, expected_var_scope);
    try std.testing.expectEqual(expected_var_scope, editor.symbols.items[value_temp_id].scope_id);

    var reads: usize = 0;
    var writes: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        const name_span = node.data.string_ref;
        if (name_span.start != value_temp_span.start or name_span.end != value_temp_span.end) continue;
        const ref_node: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(raw));
        try std.testing.expectEqual(@as(?u32, value_temp_id), transformer.getSymbolIdAt(ref_node));
        const reference = (try editor.referenceForNode(ref_node)) orelse return error.MissingValueTempReference;
        try std.testing.expectEqual(value_temp_id, @backingInt(reference.symbol_id));
        try std.testing.expectEqual(expected_scope, reference.scope_id);
        if (reference.flags.read) reads += 1;
        if (reference.flags.write) writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 1), writes);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const binding = try es_helpers.makeSyntheticBinding(&transformer, value_temp_span);
    const producer_id: @import("../semantic/symbol.zig").SymbolId = @fromBackingInt(@intCast(value_temp_id));
    try transformer.bindHoistedTempWithProducerIdentity(
        binding,
        value_temp_span,
        assignment_span,
        expected_scope,
        producer_id,
        temp_producer_id,
    );
    try std.testing.expectEqual(@as(?u32, value_temp_id), transformer.getSymbolIdAt(binding));
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 array assignment result reads use the captured producer SymbolId across hostile inputs" {
    const cases = [_][]const u8{
        "function run(input) { let a = 0; return ([a] = input); }",
        "function run(input) { let a = 0, rest = []; return ([a, ...rest] = input); }",
        "function run(input) { let a = 0, b = 0; return ([a = 2, b] = input); }",
        "function run(input) { let a = 0; return ([[a]] = input); }",
        "function run(input) { let a = 0; return ([{ value: a }] = input); }",
        "function run(input) { let a = 0; return consume(([a] = input)); }",
        "function run(input) { let _a = 99, a = 0; return ([a] = input); }",
        "function run(input) { let a = 0; { let _a = 99; return ([a] = input); } }",
        "function run(input, flag) { let a = 0; return flag ? ([a] = input) : input; }",
        "function run(input, other) { let a = 0, b = 0; return (([a] = input), ([b] = other)); }",
    };

    try std.testing.expectEqual(@as(usize, 10), cases.len);
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try checkArrayAssignmentValueTempProducerIdentity(arena.allocator(), source);
    }
}

test "#4819 reserved temp handle survives producer span lookup removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run() {}";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();

    var function_scope: ?u32 = null;
    var function_node: ?@import("../parser/ast.zig").NodeIndex = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag != .function_declaration) continue;
        function_scope = entry.value_ptr.*;
        function_node = @fromBackingInt(@intCast(entry.key_ptr.*));
    }
    const owner = function_scope orelse return error.MissingFunctionScope;
    const function_idx = function_node orelse return error.MissingFunctionNode;
    const span = parser.ast.getNode(function_idx).span;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
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
    transformer.current_scope = @fromBackingInt(@intCast(owner));

    const identity = try es_helpers.reserveTrackedTempIdentity(&transformer, span);
    const counter = transformer.temp_var_counter - 1;
    const producer_id = transformer.temp_symbol_ids_by_counter.get(counter) orelse
        return error.MissingProducerTempSymbolId;
    transformer.forgetSyntheticTempSymbolLookup(identity.span, identity.reference_scope);
    try std.testing.expect(transformer.lookupSyntheticTempSymbol(identity.span, identity.reference_scope) == null);

    const write = try es_helpers.makeTempRefFromIdentity(&transformer, identity, span, .{ .write = true });
    const read = try es_helpers.makeTempRefFromIdentity(&transformer, identity, span, .{ .read = true });
    try std.testing.expectEqual(@as(?u32, producer_id), transformer.getSymbolIdAt(write));
    try std.testing.expectEqual(@as(?u32, producer_id), transformer.getSymbolIdAt(read));
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const write_ref = (try editor.referenceForNode(write)) orelse return error.MissingProducerWriteReference;
    const read_ref = (try editor.referenceForNode(read)) orelse return error.MissingProducerReadReference;
    try std.testing.expectEqual(producer_id, @backingInt(write_ref.symbol_id));
    try std.testing.expectEqual(producer_id, @backingInt(read_ref.symbol_id));
    try std.testing.expectEqual(identity.reference_scope, write_ref.scope_id);
    try std.testing.expectEqual(identity.reference_scope, read_ref.scope_id);
    try std.testing.expect(write_ref.flags.write and !write_ref.flags.read);
    try std.testing.expect(read_ref.flags.read and !read_ref.flags.write);
}

test "#4819 assignment computed-key temp carries its producer SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run(input) { var selected = 'answer'; var answer = 0; var rest = {}; ({ [selected]: answer = 5, ...rest } = input); return [answer, rest.extra]; }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(alloc, &parser.ast, .{
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
    try std.testing.expectEqual(@as(usize, 2), transformer.temp_symbol_ids_by_counter.count());
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var verified_producers: usize = 0;
    var producer_ids = transformer.temp_symbol_ids_by_counter.iterator();
    while (producer_ids.next()) |producer_entry| {
        const producer_id: u32 = producer_entry.value_ptr.*;
        const producer_span = transformer.temp_span_by_counter.get(producer_entry.key_ptr.*) orelse
            return error.MissingComputedKeyProducerSpan;
        const producer_symbol = editor.symbols.items[@intCast(producer_id)];
        const mapped_id = transformer.lookupSyntheticTempSymbol(producer_span, producer_symbol.scope_id) orelse
            return error.MissingComputedKeyMappedIdentity;
        try std.testing.expectEqual(producer_id, @backingInt(mapped_id));
        var producer_reads: usize = 0;
        var producer_writes: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
            if (node.data.string_ref.start != producer_span.start or node.data.string_ref.end != producer_span.end) continue;
            const node_idx: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(raw));
            try std.testing.expectEqual(@as(?u32, producer_id), transformer.getSymbolIdAt(node_idx));
            const reference = (try editor.referenceForNode(node_idx)) orelse
                return error.MissingComputedKeyReference;
            try std.testing.expectEqual(producer_id, @backingInt(reference.symbol_id));
            if (reference.flags.read) producer_reads += 1;
            if (reference.flags.write) producer_writes += 1;
        }
        try std.testing.expect(producer_reads > 0);
        try std.testing.expectEqual(@as(usize, 1), producer_writes);
        verified_producers += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), verified_producers);

    _ = try transformer.finishSemanticEdit();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
}

fn checkAssignmentComputedKeyProducerIdentity(allocator: std.mem.Allocator, source: []const u8) !void {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const scope_anchor = if (std.mem.indexOf(u8, source, "getKey()") != null) "getKey" else "key";
    var expected_reference_scope: ?@import("../semantic/scope.zig").ScopeId = null;
    for (analyzer.references.items) |reference| {
        const node = parser.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference or !reference.flags.read) continue;
        if (!std.mem.eql(u8, parser.ast.getText(node.data.string_ref), scope_anchor)) continue;
        expected_reference_scope = reference.scope_id;
        break;
    }
    const exact_reference_scope = expected_reference_scope orelse return error.MissingComputedKeyScopeAnchor;

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
    try std.testing.expect(transformer.temp_symbol_ids_by_counter.count() > 0);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var producer_ids = transformer.temp_symbol_ids_by_counter.iterator();
    while (producer_ids.next()) |entry| {
        const producer_id: u32 = entry.value_ptr.*;
        const producer_span = transformer.temp_span_by_counter.get(entry.key_ptr.*) orelse
            return error.MissingComputedKeyProducerSpan;
        var reads: usize = 0;
        var writes: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
            if (node.data.string_ref.start != producer_span.start or node.data.string_ref.end != producer_span.end) continue;
            const node_idx: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(raw));
            try std.testing.expectEqual(@as(?u32, producer_id), transformer.getSymbolIdAt(node_idx));
            const reference = (try editor.referenceForNode(node_idx)) orelse return error.MissingComputedKeyReference;
            try std.testing.expectEqual(producer_id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(exact_reference_scope, reference.scope_id);
            try std.testing.expectEqual(transformer.nearestVarScope(reference.scope_id), editor.symbols.items[producer_id].scope_id);
            if (reference.flags.read) reads += 1;
            if (reference.flags.write) writes += 1;
        }
        try std.testing.expect(reads > 0 and writes > 0);
    }

    _ = try transformer.finishSemanticEdit();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
}

test "#4819 hostile: computed-key assignment producers keep exact identities across ten scopes" {
    const cases = [_][]const u8{
        "function run(input) { let key = 'x'; let value; ({ [key]: value } = input); }",
        "function run(input) { const key = 'x'; let value; ({ [key]: value = 1 } = input); }",
        "function run(input) { const key = 'x'; let value, rest; ({ [key]: value = 1, ...rest } = input); }",
        "function run(input) { const key = 'x'; let value; ({ nested: { [key]: value } } = input); }",
        "function run(input) { const key = 'x'; let value; ([{ [key]: value }] = input); }",
        "function run(input) { const key = 'x'; let value; return ({ [key]: value } = input); }",
        "function run(input) { const key = 'x'; { let value; ({ [key]: value } = input); } }",
        "function run(input) { const key = 'x'; let value; const assign = () => ({ [key]: value } = input); return assign(); }",
        "let calls = 0; function getKey() { calls++; return 'x'; } function run(input) { let value; ({ [getKey()]: value } = input); return [calls, value]; }",
        "function run(input) { const _a = 1; const key = 'x'; let value; eval('typeof _a'); ({ [key]: value } = input); return [_a, value]; }",
    };

    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try checkAssignmentComputedKeyProducerIdentity(arena.allocator(), source);
    }
}

fn checkStandaloneDestructuringTempNameMarking(source: []const u8, expected_late: bool) !void {
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
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    var temp_ids = try collectGeneratedTempSymbolIds(allocator, &transformer, edited, original_symbol_count);
    defer temp_ids.deinit(allocator);

    var temp_count: usize = 0;
    var late_temp_count: usize = 0;
    for (temp_ids.items) |raw_id| {
        const id: usize = raw_id;
        try std.testing.expect(id >= original_symbol_count and id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        temp_count += 1;
        const is_late = symbol.synthetic_kind == .standalone_temp_binding;
        try std.testing.expectEqual(expected_late, is_late);
        if (!is_late) continue;
        late_temp_count += 1;
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[@backingInt(symbol.scope_id)].get(symbol.synthetic_name));

        var bindings: usize = 0;
        var references: usize = 0;
        for (reachable) |raw_node| {
            if (transformer.ast.nodes.items[raw_node].tag != .binding_identifier) continue;
            if (raw_node < edited.symbol_ids.len and edited.symbol_ids[raw_node] == @as(u32, @intCast(id))) bindings += 1;
        }
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(reference.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[@backingInt(reference.node_index)]);
            references += 1;
        }
        try std.testing.expect(bindings > 0);
        try std.testing.expect(references > 0);
    }
    try std.testing.expect(temp_count > 0);
    try std.testing.expectEqual(expected_late, late_temp_count > 0);
}

test "#4819 standalone lowered destructuring temps finalize by SymbolId unless dynamic lookup blocks it" {
    try checkStandaloneDestructuringTempNameMarking(
        "function run() { const _a = 1; const { nested: { value } } = input; return [value, _a]; }",
        true,
    );
    try checkStandaloneDestructuringTempNameMarking(
        "function run() { const { nested: { value } } = input; return value; } function sibling() { eval('typeof _a'); }",
        false,
    );
    try checkStandaloneDestructuringTempNameMarking(
        "function run() { const _a = 1; const { [pick()]: [value = _a] } = input; return value; }",
        true,
    );
    try checkStandaloneDestructuringTempNameMarking(
        "function run() { const _a = 1; const { [pick()]: value = _a } = input; return value; }",
        true,
    );
    try checkStandaloneDestructuringTempNameMarking(
        "function run() { const _a = 1; const [[value] = []] = input; return [value, _a]; }",
        true,
    );
}

test "#4819 computed-key default destructuring temp retains its SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run() { const _a = 1; const { [pick()]: value = _a } = input; return value; }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);

    var key_id: ?usize = null;
    for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, si| {
        if (std.mem.eql(u8, symbol.synthetic_name, "_c")) key_id = si;
    }
    const id = key_id orelse return error.MissingComputedKeySymbol;
    try std.testing.expect(id >= original_symbol_count);
    const symbol = edited.symbols.items[id];
    try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[@backingInt(symbol.scope_id)].get(symbol.synthetic_name));

    var references: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(reference.node_index)) != null);
        try std.testing.expectEqual(@as(?u32, @intCast(id)), edited.symbol_ids[@backingInt(reference.node_index)]);
        const ref_node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(symbol.name.start, ref_node.data.string_ref.start);
        references += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), references);
    try std.testing.expectEqual(@as(u32, 2), symbol.reference_count);
}

test "#4819 assignment destructuring temps have exact hoisted IDs and nested read scopes" {
    const cases = [_]struct { source: []const u8, target: ESTarget, min_temps: usize }{
        .{
            .source = "function run() { const _a = 99; let x = 0; { let y = 0; ({ x, nested: { value: y } } = { x: 3, nested: { value: 4 } }); [x, y] = [x + 1, y + 1]; return [x, y, _a]; } }",
            .target = .es5,
            .min_temps = 3,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let rest; ({ x, ...rest } = { x: 3, y: 4 }); return [x, rest.y, _a]; } }",
            .target = .es2015,
            .min_temps = 1,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let y = 0; ({ nested: { value: y = 1 }, x = 2 } = {}); return [x, y, _a]; } }",
            .target = .es5,
            .min_temps = 2,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let y = 0; [x, [y]] = [1, [2]]; return [x, y, _a]; } }",
            .target = .es5,
            .min_temps = 2,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let rest; [x, ...rest] = [1, 2, 3]; return [x, rest[0], _a]; } }",
            .target = .es5,
            .min_temps = 1,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let y = 0; ({ [getKey()]: x, nested: { [getKey()]: y } } = source); return [x, y, _a]; } }",
            .target = .es5,
            .min_temps = 3,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let y = 0; ({ prop: obj.value, nested: [y], x } = source); return [x, y, _a]; } }",
            .target = .es5,
            .min_temps = 2,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let rest; ({ [key]: x = fallback(), ...rest } = source); return [x, rest.value, _a]; } }",
            .target = .es5,
            .min_temps = 2,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let y = 0; let rest; [x = fallback(), y, ...rest] = source; return [x, y, rest[0], _a]; } }",
            .target = .es5,
            .min_temps = 1,
        },
        .{
            .source = "function run() { const _a = 99; let x = 0; { let _ref = 1; let y = 0; ({ x, nested: { value: y } } = makeValue()); return [x, _ref, y, _a]; } }",
            .target = .es5,
            .min_temps = 2,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var scanner = try Scanner.init(alloc, case.source);
        var parser = Parser.init(alloc, &scanner);
        _ = try parser.parse();
        var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

        var function_scope: ?u32 = null;
        var owners = analyzer.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration)
                function_scope = entry.value_ptr.*;
        }
        const expected_function_scope = function_scope orelse return error.MissingFunctionScope;
        var nested_scope: ?u32 = null;
        var user_x_id: ?u32 = null;
        for (analyzer.symbols.items, 0..) |symbol, si| {
            const name = symbol.nameText(case.source);
            if (std.mem.eql(u8, name, "y") or std.mem.eql(u8, name, "rest")) nested_scope = @backingInt(symbol.scope_id);
            if (std.mem.eql(u8, name, "x")) user_x_id = @intCast(si);
        }
        const expected_ref_scope = nested_scope orelse return error.MissingNestedScope;
        const x_id = user_x_id orelse return error.MissingUserTarget;
        const original_symbol_count = analyzer.symbols.items.len;

        var transformer = try Transformer.init(alloc, &parser.ast, .{
            .unsupported = TransformOptions.compat.fromESTarget(case.target),
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
        // Every function-owned assignment temp in these fixtures has a known
        // producer scope, so no identity handoff may remain name/span-pending.
        try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
        const edited = (try transformer.finishSemanticEdit()).?;
        try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
        const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);

        // Assignment root and nested temps reserve their producer SymbolIds
        // before their first writes. The counter map is the later hoist
        // handoff, so every reserved ID must survive as a function-owned var.
        var producer_identity_count: usize = 0;
        var producer_identities = transformer.temp_symbol_ids_by_counter.valueIterator();
        while (producer_identities.next()) |raw_id| {
            const id: usize = @intCast(raw_id.*);
            try std.testing.expect(id >= original_symbol_count and id < edited.symbols.items.len);
            const symbol = edited.symbols.items[id];
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
            try std.testing.expectEqual(expected_function_scope, @backingInt(symbol.scope_id));
            producer_identity_count += 1;
        }
        try std.testing.expect(producer_identity_count >= case.min_temps);

        var temp_count: usize = 0;
        for (edited.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, si| {
            if (symbol.kind != .variable_var or @backingInt(symbol.scope_id) != expected_function_scope) continue;
            if (symbol.synthetic_name.len == 0 or symbol.synthetic_name[0] != '_') continue;
            try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, "_a"));
            try std.testing.expectEqual(@as(?usize, si), edited.scope_maps[expected_function_scope].get(symbol.synthetic_name));
            var binding_count: usize = 0;
            var reads: u32 = 0;
            var writes: u32 = 0;
            for (reachable) |raw| {
                if (transformer.ast.nodes.items[raw].tag == .binding_identifier and raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(si))) binding_count += 1;
            }
            for (edited.references) |ref| {
                if (@backingInt(ref.symbol_id) != si or ref.flags.declare) continue;
                try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(ref.node_index)) != null);
                try std.testing.expectEqual(expected_ref_scope, @backingInt(ref.scope_id));
                try std.testing.expectEqual(@as(?u32, @intCast(si)), edited.symbol_ids[@backingInt(ref.node_index)]);
                if (ref.flags.read) reads += 1;
                if (ref.flags.write) writes += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), binding_count);
            try std.testing.expect(reads > 0 and writes > 0);
            try std.testing.expectEqual(reads + writes, symbol.reference_count);
            try std.testing.expectEqual(writes, symbol.write_count);
            temp_count += 1;
        }
        try std.testing.expect(temp_count >= case.min_temps);

        var user_target_count: usize = 0;
        for (reachable) |raw| {
            if (raw < transformer.parser_node_count or raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != x_id) continue;
            const tag = transformer.ast.nodes.items[raw].tag;
            if (tag != .identifier_reference and tag != .assignment_target_identifier) continue;
            user_target_count += 1;
        }
        try std.testing.expect(user_target_count > 0);
    }
}

test "#4819 for-of destructuring temps get exact IDs before emitted reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run(items) { let total = 0; for (const { value, nested: { deep } } of items) total += value + deep; return total; }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration)
            function_scope = entry.value_ptr.*;
    }
    const expected_scope = function_scope orelse return error.MissingFunctionScope;
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);
    var temp_ids = try collectGeneratedTempSymbolIds(alloc, &transformer, edited, original_symbol_count);
    defer temp_ids.deinit(alloc);

    var temp_count: usize = 0;
    for (temp_ids.items) |id| {
        try std.testing.expect(id >= original_symbol_count and id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        if (symbol.kind != @import("../semantic/symbol.zig").SymbolKind.variable_var or symbol.reference_count == 0) continue;
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
        try std.testing.expectEqual(expected_scope, @backingInt(symbol.scope_id));
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[expected_scope].get(symbol.synthetic_name));

        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var reference_count: u32 = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != id or ref.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(ref.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(ref.node_index)]);
            try std.testing.expect(ref.flags.read or ref.flags.write);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
        try std.testing.expectEqual(reference_count, symbol.reference_count);
        temp_count += 1;
    }
    try std.testing.expect(temp_count >= 2);
}

test "#4819 for-of loop helper destructuring temps carry exact IDs into nested pattern reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run(items) { for (var { value, nested: { deep } } of items) use(value, deep); }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration)
            function_scope = entry.value_ptr.*;
    }
    const expected_symbol_scope = function_scope orelse return error.MissingFunctionScope;
    var for_of: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .for_of_statement) for_of = @fromBackingInt(@intCast(raw));
    }
    const for_of_idx = for_of orelse return error.MissingForOf;
    const for_of_node = parser.ast.getNode(for_of_idx);
    const left = for_of_node.data.ternary.a;
    const reference_scope = analyzer.scope_owner_map.get(@backingInt(for_of_idx)) orelse expected_symbol_scope;
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(@intCast(reference_scope));
    const element_name = try transformer.ast.addUniqueString("element");
    const element = try transformer.ast.addNode(.{
        .tag = .identifier_reference,
        .span = for_of_node.span,
        .data = .{ .string_ref = element_name },
    });

    const emitted = try es_helpers.buildForOfLoopVarAssign(&transformer, left, element, for_of_node.span);
    try std.testing.expectEqual(.variable_declaration, transformer.ast.getNode(emitted).tag);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;

    var temp_count: usize = 0;
    for (editor.symbols.items[original_symbol_count..], original_symbol_count..) |symbol, raw_id| {
        if (symbol.kind != .variable_var or symbol.synthetic_name.len == 0 or symbol.synthetic_name[0] != '_') continue;
        const id: u32 = @intCast(raw_id);
        try std.testing.expectEqual(expected_symbol_scope, @backingInt(symbol.scope_id));
        try std.testing.expectEqual(@as(?usize, raw_id), editor.scope_maps.items[expected_symbol_scope].get(symbol.synthetic_name));

        var binding_count: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .binding_identifier and transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))) == id)
                binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var reference_count: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) != raw_id or reference.flags.declare) continue;
            try std.testing.expectEqual(reference_scope, @backingInt(reference.scope_id));
            try std.testing.expectEqual(@as(?u32, id), transformer.getSymbolIdAt(reference.node_index));
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
        temp_count += 1;
    }
    try std.testing.expect(temp_count >= 2);
}

test "#4819 destructuring shorthand moves the exact assignment reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function run() { let x = 1; { let x = 2; const assigned = ({ x } = { x: 3 }); return [x, assigned.x]; } }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var source_target: ?@import("../parser/ast.zig").NodeIndex = null;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .assignment_target_property_identifier) continue;
        const key = node.data.binary.left;
        if (!std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(key).data.string_ref), "x")) continue;
        source_target = key;
    }
    const target = source_target orelse return error.MissingAssignmentTarget;
    const source_raw = @backingInt(target);
    const target_symbol = analyzer.symbol_ids.items[source_raw] orelse return error.MissingTargetSymbol;
    const source_reference = for (analyzer.references.items) |reference| {
        if (reference.node_index == target) break reference;
    } else return error.MissingTargetReference;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);

    try std.testing.expect(std.mem.indexOfScalar(u32, reachable, source_raw) == null);
    for (edited.references) |reference| {
        try std.testing.expect(reference.node_index != target);
    }
    try std.testing.expectEqualStrings("", analyzer.symbols.items[target_symbol].synthetic_name);
    var has_shadowed_outer_x = false;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        if (@as(u32, @intCast(index)) == target_symbol or !std.mem.eql(u8, symbol.nameText(source), "x")) continue;
        has_shadowed_outer_x = true;
    }
    try std.testing.expect(has_shadowed_outer_x);

    var generated_target_count: usize = 0;
    for (reachable) |raw| {
        if (raw < transformer.parser_node_count or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] != @as(?u32, target_symbol)) continue;
        const node: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@intCast(raw));
        if (transformer.ast.getNode(node).tag != .identifier_reference) continue;
        const reference = for (edited.references) |candidate| {
            if (candidate.node_index == node) break candidate;
        } else return error.MissingGeneratedTargetReference;
        try std.testing.expectEqual(target_symbol, @backingInt(reference.symbol_id));
        try std.testing.expectEqual(source_reference.scope_id, reference.scope_id);
        try std.testing.expect(reference.flags.write);
        generated_target_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), generated_target_count);

    var references: usize = 0;
    var writes: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != target_symbol) continue;
        references += 1;
        if (reference.flags.write) writes += 1;
    }
    const symbol = edited.symbols.items[target_symbol];
    try std.testing.expectEqual(symbol.reference_count, references);
    try std.testing.expectEqual(symbol.write_count, writes);
    try std.testing.expectEqual(@as(usize, 2), references);
    try std.testing.expectEqual(@as(usize, 1), writes);
}

test "#4819 ES5 destructuring temps keep exact IDs in hoisted function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function f() { const _a = 99; { const { x } = { x: 1 }; const {} = {}; console.log(x, _a); } }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (parser.ast.nodes.items[entry.key_ptr.*].tag == .function_declaration)
            function_scope = entry.value_ptr.*;
    }
    const expected_scope = function_scope orelse return error.MissingFunctionScope;
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);
    var temp_ids = try collectGeneratedTempSymbolIds(alloc, &transformer, edited, original_symbol_count);
    defer temp_ids.deinit(alloc);

    var temp_count: usize = 0;
    var unused_count: usize = 0;
    var used_count: usize = 0;
    for (temp_ids.items) |id| {
        try std.testing.expect(id >= original_symbol_count and id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        try std.testing.expectEqual(expected_scope, @backingInt(symbol.scope_id));
        try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, "_a"));
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[expected_scope].get(symbol.synthetic_name));
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        // A function-scoped var temp may have both its explicit hoist and a
        // source-position initializer declaration. They share this one ID.
        try std.testing.expect(binding_count > 0);
        var ref_count: usize = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != id or ref.flags.declare) continue;
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(ref.node_index)) != null);
            try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(ref.node_index)]);
            try std.testing.expect(ref.flags.read or ref.flags.write);
            ref_count += 1;
        }
        try std.testing.expectEqual(@as(usize, symbol.reference_count + symbol.write_count), ref_count);
        if (ref_count == 0) unused_count += 1 else used_count += 1;
        temp_count += 1;
    }
    // The empty destructuring still evaluates its initializer through an
    // emitted temp. It has a SymbolId at creation time, with no references.
    try std.testing.expectEqual(@as(usize, 2), temp_count);
    try std.testing.expectEqual(@as(usize, 1), unused_count);
    try std.testing.expectEqual(@as(usize, 1), used_count);
}

test "#4819 ES2015 object-rest temps keep const and let block scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "function f() { let _a = 9; { const { x, ...tail } = { x: 1, y: 2 }; let { z, ...more } = { z: 3, w: 4 }; return x + z + tail.y + more.w + _a; } }";
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var block_scope: ?u32 = null;
    for (analyzer.symbols.items) |symbol| {
        if (std.mem.eql(u8, parser.ast.getText(symbol.name), "x")) block_scope = @backingInt(symbol.scope_id);
    }
    const expected_scope = block_scope orelse return error.MissingBlockScope;
    const original_symbol_count = analyzer.symbols.items.len;

    var transformer = try Transformer.init(alloc, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
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
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const reachable = try ast_walk.collectReachableNodeIndices(alloc, transformer.ast);
    var temp_ids = try collectGeneratedTempSymbolIds(alloc, &transformer, edited, original_symbol_count);
    defer temp_ids.deinit(alloc);

    var const_count: usize = 0;
    var let_count: usize = 0;
    for (temp_ids.items) |id| {
        try std.testing.expect(id >= original_symbol_count and id < edited.symbols.items.len);
        const symbol = edited.symbols.items[id];
        try std.testing.expectEqual(expected_scope, @backingInt(symbol.scope_id));
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[expected_scope].get(symbol.synthetic_name));
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
            if (raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        try std.testing.expect(symbol.reference_count > 0);
        switch (symbol.kind) {
            .variable_const => const_count += 1,
            .variable_let => let_count += 1,
            else => return error.WrongTempKind,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), const_count);
    try std.testing.expectEqual(@as(usize, 1), let_count);
}
