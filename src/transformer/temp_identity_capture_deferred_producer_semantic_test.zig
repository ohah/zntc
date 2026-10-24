const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const ast_mod = @import("../parser/ast.zig");
const Span = @import("../lexer/token.zig").Span;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const es_helpers = @import("es_helpers.zig");
const ES2015Destructuring = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
const ES2015Computed = @import("es2015_computed.zig").ES2015Computed(Transformer);
const parameter_environment = @import("parameter_environment.zig");
const stage3_helpers = @import("transformer/stage3_decorator_helpers.zig");

const Consumer = enum {
    direct_identity,
    assignment_target,
    object_destructuring,
    array_destructuring,
    computed_object,
    runtime_key_name,
    stage3_callback,
};

const Case = struct {
    source: []const u8,
    consumer: Consumer,
};

const SavedReference = struct {
    node: ast_mod.NodeIndex,
    scope: ScopeId,
    flags: @import("../semantic/mod.zig").ReferenceFlags,
    producer_id: u64,
    name_span: Span,
};

fn sameSpan(a: Span, b: Span) bool {
    return a.start == b.start and a.end == b.end;
}

fn findNode(transformer: *Transformer, tag: ast_mod.Node.Tag) ?ast_mod.NodeIndex {
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == tag) return @fromBackingInt(@intCast(@as(u32, @intCast(raw))));
    }
    return null;
}

fn scopeForNode(transformer: *Transformer, root: ast_mod.NodeIndex, target: ast_mod.NodeIndex) ScopeId {
    var best = transformer.scope_owner_map.get(@backingInt(root)) orelse return .none;
    const target_span = transformer.ast.getNode(target).span;
    var best_width: u32 = std.math.maxInt(u32);
    var owners = transformer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.key_ptr.* >= transformer.ast.nodes.items.len) continue;
        const owner = transformer.ast.getNode(@fromBackingInt(@intCast(entry.key_ptr.*)));
        if (owner.span.start > target_span.start or owner.span.end < target_span.end) continue;
        const width = owner.span.end - owner.span.start;
        if (width >= best_width) continue;
        best = entry.value_ptr.*;
        best_width = width;
    }
    return @fromBackingInt(@intCast(best));
}

fn allocatorProducerForSpan(transformer: *Transformer, span: Span) ?u64 {
    var spans = transformer.temp_span_by_counter.iterator();
    while (spans.next()) |entry| {
        if (!sameSpan(entry.value_ptr.*, span)) continue;
        return transformer.temp_producer_id_by_counter.get(entry.key_ptr.*);
    }
    return null;
}

fn runCase(case: Case) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, case.source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;

    const anchor = findNode(&transformer, .function_declaration) orelse return error.MissingFunctionAnchor;
    transformer.current_scope = scopeForNode(&transformer, root, anchor);
    if (transformer.current_scope.isNone()) return error.MissingProducerScope;
    var producer_scope = transformer.current_scope;
    // Force the deferred-owner branch used by static fields and state-machine
    // callbacks while invoking each production consumer directly.
    transformer.static_field_initializer_depth = 1;

    var expected_scope = producer_scope;
    switch (case.consumer) {
        .direct_identity => {
            const span = transformer.ast.getNode(anchor).span;
            const identity = try es_helpers.reserveTrackedTempIdentity(&transformer, span);
            try std.testing.expect(identity.symbol_id == null);
            try std.testing.expect(identity.temp_producer_id != null);
            _ = try es_helpers.makeTempRefFromIdentity(&transformer, identity, span, .{ .write = true });
            _ = try es_helpers.makeTempRefFromIdentity(&transformer, identity, span, .{ .read = true });
        },
        .assignment_target => {
            const target_node = findNode(&transformer, .computed_member_expression) orelse return error.MissingComputedAssignmentTarget;
            transformer.current_scope = scopeForNode(&transformer, root, target_node);
            producer_scope = transformer.current_scope;
            expected_scope = producer_scope;
            const target = (try es_helpers.prepareAssignmentTargetRef(&transformer, target_node, transformer.ast.getNode(target_node).span)) orelse
                return error.MissingPreparedAssignmentTarget;
            try es_helpers.trackAssignmentTargetRefs(&transformer, target, true, true);
        },
        .object_destructuring, .array_destructuring => {
            const tag: ast_mod.Node.Tag = if (case.consumer == .object_destructuring) .object_pattern else .array_pattern;
            const pattern = findNode(&transformer, tag) orelse return error.MissingDestructuringPattern;
            transformer.current_scope = scopeForNode(&transformer, root, pattern);
            producer_scope = transformer.current_scope;
            expected_scope = producer_scope;
            const rhs = try es_helpers.makeNumericLiteral(&transformer, 17);
            _ = try ES2015Destructuring.lowerBindingPatternAssignment(
                &transformer,
                transformer.ast.getNode(pattern),
                rhs,
                transformer.ast.getNode(pattern).span,
                null,
            );
        },
        .computed_object => {
            var object: ?ast_mod.NodeIndex = null;
            for (transformer.ast.nodes.items, 0..) |node, raw| {
                if (node.tag != .object_expression or !ES2015Computed.hasComputedProperty(&transformer, node)) continue;
                object = @fromBackingInt(@intCast(@as(u32, @intCast(raw))));
                break;
            }
            const object_node = object orelse return error.MissingComputedObject;
            transformer.current_scope = scopeForNode(&transformer, root, object_node);
            producer_scope = transformer.current_scope;
            expected_scope = producer_scope;
            _ = try ES2015Computed.lowerComputedProperties(&transformer, transformer.ast.getNode(object_node));
        },
        .runtime_key_name => {
            const span = transformer.ast.getNode(anchor).span;
            const key_expr = try es_helpers.makeNumericLiteral(&transformer, 23);
            const captured = try parameter_environment.captureRuntimeKey(&transformer, key_expr, span);
            try std.testing.expect(captured.temp.temp_producer_id != null);
            const value = try es_helpers.makeNumericLiteral(&transformer, 1);
            _ = try parameter_environment.nameByTemp(&transformer, value, captured.temp, null, span);
        },
        .stage3_callback => {
            const callback = findNode(&transformer, .function_expression) orelse return error.MissingGeneratedCallbackAnchor;
            expected_scope = scopeForNode(&transformer, root, callback);
            if (expected_scope.isNone()) return error.MissingCallbackScope;
            const span = transformer.ast.getNode(anchor).span;
            const identity = try es_helpers.reserveTrackedTempIdentity(&transformer, span);
            try std.testing.expect(identity.symbol_id == null);
            const reference = try es_helpers.makeTempVarRef(&transformer, identity.span, span);
            try stage3_helpers.attachNameTempReference(&transformer, identity, identity.span, reference, expected_scope);
        },
    }

    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expect(transformer.pending_temp_producer_refs.items.len > 0);
    var saved: [32]SavedReference = undefined;
    var saved_len: usize = 0;
    var saw_read = false;
    var saw_write = false;
    for (transformer.pending_temp_producer_refs.items) |pending| {
        if (saved_len == saved.len) return error.TooManyProducerReferences;
        try std.testing.expect(pending.temp_producer_id != 0);
        try std.testing.expectEqual(expected_scope, pending.scope);
        try std.testing.expectEqual(pending.temp_producer_id, allocatorProducerForSpan(&transformer, pending.name_span));
        try std.testing.expect(pending.flags.read != pending.flags.write);
        saw_read = saw_read or pending.flags.read;
        saw_write = saw_write or pending.flags.write;
        const node = transformer.ast.getNode(pending.node);
        try std.testing.expect(node.tag == .identifier_reference or node.tag == .assignment_target_identifier);
        try std.testing.expect(sameSpan(node.data.string_ref, pending.name_span));
        saved[saved_len] = .{
            .node = pending.node,
            .scope = pending.scope,
            .flags = pending.flags,
            .producer_id = pending.temp_producer_id,
            .name_span = pending.name_span,
        };
        saved_len += 1;
    }
    if (case.consumer == .assignment_target) try std.testing.expect(saw_read and saw_write);

    // A wrong producer handle must leave the references unbound; the correct
    // producer then binds those same references by ID.
    const first = saved[0];
    const binding_scope = transformer.nearestVarScope(producer_scope);
    const wrong_binding = try es_helpers.makeSyntheticBinding(&transformer, first.name_span);
    try transformer.bindHoistedTempWithProducerIdentity(
        wrong_binding,
        first.name_span,
        transformer.ast.getNode(anchor).span,
        binding_scope,
        null,
        std.math.maxInt(u64),
    );
    try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(wrong_binding));
    try std.testing.expectEqual(saved_len, transformer.pending_temp_producer_refs.items.len);

    var bound_ids: [32]u64 = undefined;
    var bound_len: usize = 0;
    for (saved[0..saved_len]) |reference| {
        var already_bound = false;
        for (bound_ids[0..bound_len]) |producer_id| already_bound = already_bound or producer_id == reference.producer_id;
        if (already_bound) continue;
        const binding = try es_helpers.makeSyntheticBinding(&transformer, reference.name_span);
        try transformer.bindHoistedTempWithProducerIdentity(
            binding,
            reference.name_span,
            transformer.ast.getNode(anchor).span,
            binding_scope,
            null,
            reference.producer_id,
        );
        const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingProducerBinding;
        const editor = if (transformer.semantic_editor) |*current| current else return error.MissingSemanticEditor;
        const symbol = editor.symbols.items[symbol_id];
        try std.testing.expectEqual(SymbolKind.variable_var, symbol.kind);
        try std.testing.expectEqual(binding_scope, symbol.scope_id);
        try std.testing.expect(sameSpan(symbol.name, reference.name_span));
        bound_ids[bound_len] = reference.producer_id;
        bound_len += 1;
    }

    for (saved[0..saved_len]) |reference| {
        const raw_id = transformer.getSymbolIdAt(reference.node) orelse return error.UnboundProducerReference;
        const editor = if (transformer.semantic_editor) |*current| current else return error.MissingSemanticEditor;
        const resolved = (editor.referenceForNode(reference.node) catch return error.MissingResolvedReference) orelse
            return error.MissingResolvedReference;
        try std.testing.expectEqual(raw_id, @backingInt(resolved.symbol_id));
        try std.testing.expectEqual(reference.scope, resolved.scope_id);
        try std.testing.expect(std.meta.eql(reference.flags, resolved.flags));
        try std.testing.expect(editor.symbolVisibleFrom(resolved.symbol_id, resolved.scope_id));
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
}

test "#6118 TempIdentityCapture carries deferred producer IDs across ten hostile consumers" {
    const cases = [_]Case{
        .{ .source = "function* target(obj, key) { eval('typeof _a'); return obj[key]; }", .consumer = .direct_identity },
        .{ .source = "function target(obj, key) { { let _a = 1; } return obj[key]; }", .consumer = .assignment_target },
        .{ .source = "function* target(obj, key) { function nested() { return obj[key]; } return obj[getKey()]; }", .consumer = .assignment_target },
        .{ .source = "function* target(obj) { const { value: local } = obj; return local; }", .consumer = .object_destructuring },
        .{ .source = "function target(obj) { return function nested() { const [first, second] = obj; return first + second; }; }", .consumer = .array_destructuring },
        .{ .source = "function* target(key, value) { return { [key]: value, plain: 1 }; }", .consumer = .computed_object },
        .{ .source = "function target(key, fn) { return { get [key]() { return fn; }, set [key](value) { fn(value); } }; }", .consumer = .computed_object },
        .{ .source = "function* target(key, fn) { return { [key]: function() { return fn; } }; }", .consumer = .runtime_key_name },
        .{ .source = "const _a = 1; function target(key, fn) { eval('typeof _a'); return { [key]: () => fn }; }", .consumer = .runtime_key_name },
        .{ .source = "function target(key) { return function access() { return key; }; }", .consumer = .stage3_callback },
    };
    for (cases) |case| try runCase(case);
}

test "#6118 TempIdentityCapture keeps producer IDs distinct when allocator slots are reused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function target() { return 1; } function next() { return 2; }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".js");
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    const anchor = findNode(&transformer, .function_declaration) orelse return error.MissingFunctionAnchor;
    transformer.current_scope = scopeForNode(&transformer, root, anchor);
    transformer.static_field_initializer_depth = 1;
    transformer.temp_var_counter = 100;
    const span = transformer.ast.getNode(anchor).span;

    const first = try es_helpers.reserveTrackedTempIdentity(&transformer, span);
    const first_id = first.temp_producer_id orelse return error.MissingFirstProducerId;
    _ = try es_helpers.makeTempRefFromIdentity(&transformer, first, span, .{ .write = true });
    var function_count: usize = 0;
    var second_anchor: ?ast_mod.NodeIndex = null;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        function_count += 1;
        if (function_count == 2) second_anchor = @fromBackingInt(@intCast(@as(u32, @intCast(raw))));
    }
    const second_function = second_anchor orelse return error.MissingSecondFunction;
    transformer.current_scope = scopeForNode(&transformer, root, second_function);
    transformer.temp_var_counter = 100;
    const second = try es_helpers.reserveTrackedTempIdentity(&transformer, span);
    const second_id = second.temp_producer_id orelse return error.MissingSecondProducerId;
    _ = try es_helpers.makeTempRefFromIdentity(&transformer, second, span, .{ .read = true });
    try std.testing.expect(std.mem.eql(u8, transformer.ast.getText(first.span), transformer.ast.getText(second.span)));
    try std.testing.expect(first_id != second_id);

    try std.testing.expectEqual(@as(usize, 2), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expectEqual(first_id, transformer.pending_temp_producer_refs.items[0].temp_producer_id);
    try std.testing.expectEqual(second_id, transformer.pending_temp_producer_refs.items[1].temp_producer_id);
}
