const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const NodeIndex = ast_mod.NodeIndex;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const Transformer = @import("transformer.zig").Transformer;
const ObjectSuperHomeIdentity = Transformer.ObjectSuperHomeIdentity;
const TransformOptions = @import("transformer.zig").TransformOptions;
const es_helpers = @import("es_helpers.zig");
const object_super = @import("object_super.zig");

test "#4819 lowered default object-super home temp reserves and reuses its function SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function make(input = {
        \\  __proto__: this.base,
        \\  receiver: this,
        \\  method() { return super.value + 2; }
        \\}) {
        \\  return input.method.call(input.receiver);
        \\}
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var function_scope: ?ScopeId = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner: ast_mod.NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        const node = parser.ast.getNode(owner);
        if (node.tag != .function_declaration) continue;
        const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone() or !std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(name).data.string_ref), "make")) continue;
        function_scope = @fromBackingInt(@intCast(entry.value_ptr.*));
        break;
    }
    const expected_scope = function_scope orelse return error.MissingFunctionScope;
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

    _ = try transformer.transform();
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var home_id: ?SymbolId = null;
    for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, raw_id| {
        if (symbol.kind == .variable_var and std.mem.eql(u8, symbol.synthetic_name, "_a")) {
            try std.testing.expect(home_id == null);
            home_id = @fromBackingInt(@intCast(@as(u32, @intCast(raw_id))));
        }
    }
    const id = home_id orelse return error.MissingObjectHomeSymbol;
    const symbol = editor.symbols.items[@backingInt(id)];
    try std.testing.expectEqual(@backingInt(expected_scope), @backingInt(symbol.scope_id));
    try std.testing.expect(!transformer.pending_temp_ref_chains.contains(transformer.currentPendingTempRefKey(symbol.name)));

    var live_reference_count: usize = 0;
    var live_read_count: usize = 0;
    var live_write_count: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.symbol_id != id or reference.node_index.isNone()) continue;
        try std.testing.expect(editor.symbolVisibleFrom(id, reference.scope_id));
        try std.testing.expect(reference.flags.read != reference.flags.write);
        if (reference.flags.read) live_read_count += 1;
        if (reference.flags.write) live_write_count += 1;
        live_reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live_reference_count);
    try std.testing.expectEqual(@as(usize, 1), live_read_count);
    try std.testing.expectEqual(@as(usize, 1), live_write_count);

    const edited = (try transformer.finishSemanticEdit()).?;
    var binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == @as(?u32, @intCast(@backingInt(id)))) binding_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);

    var reference_count: usize = 0;
    for (edited.references) |reference| {
        if (reference.symbol_id == id and !reference.node_index.isNone()) reference_count += 1;
    }
    try std.testing.expectEqual(live_reference_count, reference_count);
}

test "#4819 object-super wrapper parameter carries its exact late-name identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\var base = { read() { return this.input; } };
        \\var methods = { read() { return super.read(); } };
        \\Object.setPrototypeOf(methods, base);
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
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

    _ = try transformer.transform();
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var home_id: ?SymbolId = null;
    for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, raw_id| {
        if (symbol.synthetic_kind != .object_super_home_binding) continue;
        try std.testing.expect(home_id == null);
        home_id = @fromBackingInt(@intCast(@as(u32, @intCast(raw_id))));
        try std.testing.expectEqual(SymbolKind.parameter, symbol.kind);
        try std.testing.expectEqualStrings("_obj", symbol.output_name_hint);
        try std.testing.expect(!symbol.scope_id.isNone());
    }
    const id = home_id orelse return error.MissingObjectSuperHomeOutputSymbol;
    const edited = (try transformer.finishSemanticEdit()).?;
    var binding_count: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == @as(?u32, @intCast(@backingInt(id)))) binding_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), binding_count);
}

fn findHomeWriteReference(
    transformer: *Transformer,
    wrapped: ast_mod.NodeIndex,
    object: ast_mod.NodeIndex,
) !ast_mod.NodeIndex {
    var queue: std.ArrayList(ast_mod.NodeIndex) = .empty;
    defer queue.deinit(transformer.allocator);
    try queue.append(transformer.allocator, wrapped);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(transformer.allocator);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const node_idx = queue.items[cursor];
        if (node_idx.isNone() or @backingInt(node_idx) >= transformer.ast.nodes.items.len) continue;
        const raw = @backingInt(node_idx);
        if (seen.contains(raw)) continue;
        try seen.put(transformer.allocator, raw, {});
        const node = transformer.ast.getNode(node_idx);
        if (node.tag == .assignment_expression and node.data.binary.right == object)
            return node.data.binary.left;
        var it = ast_walk.children(transformer.ast, node);
        while (it.next()) |child| try queue.append(transformer.allocator, child);
    }
    return error.MissingHomeWriteReference;
}

fn checkObjectSuperHomeReferenceHandle(source: []const u8, home_wrap: object_super.Home.Wrap) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    const program = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var owner_scope: ?ScopeId = null;
    var owner_iter = analyzer.scope_owner_map.iterator();
    while (owner_iter.next()) |entry| {
        const owner: ast_mod.NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        const node = parser.ast.getNode(owner);
        if (node.tag != .function_declaration) continue;
        const name = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone() or !std.mem.eql(u8, parser.ast.getText(parser.ast.getNode(name).data.string_ref), "owner")) continue;
        owner_scope = @fromBackingInt(@intCast(entry.value_ptr.*));
        break;
    }
    const scope = owner_scope orelse return error.MissingOwnerFunctionScope;
    const span = parser.ast.getNode(program).span;

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
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = scope;

    const home_span = try es_helpers.makeTempVarSpan(&transformer);
    const home_identity = ObjectSuperHomeIdentity{ .producer_node = program, .span = home_span };
    const first_proto = try object_super.buildHomeProto(&transformer, home_identity, span);
    const first_ref = transformer.object_super_home_references.items[
        transformer.object_super_home_references.items.len - 1
    ].node;
    const second_proto = try object_super.buildHomeProto(&transformer, home_identity, span);
    const second_ref = transformer.object_super_home_references.items[
        transformer.object_super_home_references.items.len - 1
    ].node;

    // Model a distinct generated reference with the same spelling. A spelling
    // walk used to mistake this node for an object-super home read and attempt
    // to bind its already-owned reference to the home SymbolId.
    const decoy_name = try transformer.ast.addString("__object_super_decoy");
    const decoy_binding = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, decoy_name);
    const decoy_id = (try transformer.declareSyntheticInScope(
        decoy_binding,
        span,
        .variable_var,
        scope,
    )) orelse return error.MissingDecoySymbolId;
    const decoy_ref = try es_helpers.makeTempVarRef(&transformer, home_span, span);
    try transformer.addSyntheticRefInScope(decoy_ref, decoy_id, scope, .{ .read = true });

    var other_home_identity: ?ObjectSuperHomeIdentity = null;
    var other_home_proto: ?NodeIndex = null;
    var other_home_ref: ?NodeIndex = null;
    if (home_wrap != .assign) {
        // Deliberately reuse the exact name span under a distinct producer.
        // Deferred reference grouping must follow the producer NodeIndex.
        const empty_members = try transformer.ast.addNodeList(&.{});
        const other_producer = try transformer.ast.addNode(.{
            .tag = .object_expression,
            .span = span,
            .data = .{ .list = empty_members },
        });
        const other_identity = ObjectSuperHomeIdentity{ .producer_node = other_producer, .span = home_span };
        const other_proto = try object_super.buildHomeProto(&transformer, other_identity, span);
        other_home_identity = other_identity;
        other_home_proto = other_proto;
        other_home_ref = transformer.object_super_home_references.items[
            transformer.object_super_home_references.items.len - 1
        ].node;
    }

    const values = try transformer.ast.addNodeList(&.{ first_proto, second_proto, decoy_ref });
    const root = try transformer.ast.addNode(.{
        .tag = .array_expression,
        .span = span,
        .data = .{ .list = values },
    });
    const wrapped = try object_super.wrapWithHome(&transformer, .{ .identity = home_identity, .wrap = home_wrap }, root, span);
    const write_ref = try findHomeWriteReference(&transformer, wrapped, root);
    const home_id = switch (home_wrap) {
        .assign => blk: {
            const hoisted_binding = try es_helpers.makeExactSyntheticBindingFromSpan(&transformer, home_span);
            if (transformer.getSymbolIdAt(write_ref)) |raw_id| {
                const producer_id = @as(SymbolId, @fromBackingInt(@intCast(raw_id)));
                try transformer.bindHoistedTempWithProducerSymbol(hoisted_binding, home_span, span, scope, producer_id);
                break :blk producer_id;
            }
            try std.testing.expect(transformer.pending_temp_ref_chains.contains(transformer.currentPendingTempRefKey(home_span)));
            try transformer.bindHoistedTemp(hoisted_binding, home_span, span, scope);
            const raw_id = transformer.getSymbolIdAt(hoisted_binding) orelse return error.MissingHomeSymbolId;
            break :blk @as(SymbolId, @fromBackingInt(@intCast(raw_id)));
        },
        .arrow, .function, .function_with_this => blk: {
            const raw_id = transformer.getSymbolIdAt(write_ref) orelse return error.MissingHomeSymbolId;
            break :blk @as(SymbolId, @fromBackingInt(@intCast(raw_id)));
        },
    };

    try std.testing.expectEqual(@as(?u32, @backingInt(home_id)), transformer.getSymbolIdAt(write_ref));
    try std.testing.expectEqual(@as(?u32, @backingInt(home_id)), transformer.getSymbolIdAt(first_ref));
    try std.testing.expectEqual(@as(?u32, @backingInt(home_id)), transformer.getSymbolIdAt(second_ref));
    try std.testing.expectEqual(@as(?u32, @backingInt(decoy_id)), transformer.getSymbolIdAt(decoy_ref));
    if (other_home_identity) |other_identity| {
        const other_ref = other_home_ref.?;
        try std.testing.expectEqual(@as(usize, 1), transformer.object_super_home_references.items.len);
        try std.testing.expectEqual(other_ref, transformer.object_super_home_references.items[0].node);
        try std.testing.expectEqual(@as(?u32, null), transformer.getSymbolIdAt(other_ref));

        const other_root = try transformer.ast.addNode(.{
            .tag = .array_expression,
            .span = span,
            .data = .{ .list = try transformer.ast.addNodeList(&.{other_home_proto.?}) },
        });
        const other_wrapped = try object_super.wrapWithHome(
            &transformer,
            .{ .identity = other_identity, .wrap = home_wrap },
            other_root,
            span,
        );
        const other_write_ref = try findHomeWriteReference(&transformer, other_wrapped, other_root);
        const other_raw_id = transformer.getSymbolIdAt(other_write_ref) orelse return error.MissingOtherHomeSymbolId;
        const other_home_id: SymbolId = @fromBackingInt(@intCast(other_raw_id));
        try std.testing.expect(other_home_id != home_id);
        try std.testing.expectEqual(@as(?u32, @backingInt(other_home_id)), transformer.getSymbolIdAt(other_ref));
        try std.testing.expectEqual(@as(usize, 0), transformer.object_super_home_references.items.len);
    } else {
        try std.testing.expectEqual(@as(usize, 0), transformer.object_super_home_references.items.len);
    }

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var home_reads: usize = 0;
    var home_writes: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.symbol_id != home_id) continue;
        try std.testing.expect(editor.symbolVisibleFrom(home_id, reference.scope_id));
        if (reference.flags.read) home_reads += 1;
        if (reference.flags.write) home_writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), home_reads);
    try std.testing.expectEqual(@as(usize, 1), home_writes);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
}

test "#6004 object-super home identity follows its object expression node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function owner() { const first = { method() { return super.value; } }; const second = { method() { return super.value; } }; return [first, second]; }";

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var producer_nodes: [2]NodeIndex = undefined;
    var method_extras: [2]u32 = undefined;
    var producer_count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw_index| {
        if (producer_count == producer_nodes.len) break;
        if (node.tag != .object_expression) continue;
        const candidate_producer: NodeIndex = @fromBackingInt(@intCast(raw_index));
        var member_index: u32 = 0;
        var candidate_method_extra: ?u32 = null;
        while (member_index < node.data.list.len) : (member_index += 1) {
            const raw_member = parser.ast.extra_data.items[node.data.list.start + member_index];
            const member: NodeIndex = @fromBackingInt(@intCast(raw_member));
            if (parser.ast.getNode(member).tag == .method_definition) {
                candidate_method_extra = parser.ast.getNode(member).data.extra;
                break;
            }
        }
        if (candidate_method_extra) |extra| {
            producer_nodes[producer_count] = candidate_producer;
            method_extras[producer_count] = extra;
            producer_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), producer_count);
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .emit_runtime_helper_imports = true,
    });
    transformer.semantic_edit_enabled = true;
    const mark = transformer.object_super_homes.items.len;
    const first_home = (try object_super.prepareHome(&transformer, producer_nodes[0], true)) orelse return error.MissingFirstObjectHome;
    const second_mark = transformer.object_super_homes.items.len;
    const second_home = (try object_super.prepareHome(&transformer, producer_nodes[1], true)) orelse return error.MissingSecondObjectHome;
    try std.testing.expectEqual(producer_nodes[0], first_home.identity.producer_node);
    try std.testing.expectEqual(producer_nodes[1], second_home.identity.producer_node);
    try std.testing.expect(first_home.identity.producer_node != second_home.identity.producer_node);
    const first_method_home = object_super.lookup(&transformer, method_extras[0]) orelse return error.MissingFirstMethodHome;
    const second_method_home = object_super.lookup(&transformer, method_extras[1]) orelse return error.MissingSecondMethodHome;
    try std.testing.expectEqual(first_home.identity, first_method_home);
    try std.testing.expectEqual(second_home.identity, second_method_home);

    const outer_saved = object_super.enterMethod(&transformer, first_method_home);
    const inner_saved = object_super.enterMethod(&transformer, second_method_home);
    try std.testing.expectEqual(second_home.identity, transformer.current_super_home_object.?);
    object_super.leaveMethod(&transformer, inner_saved);
    try std.testing.expectEqual(first_home.identity, transformer.current_super_home_object.?);
    object_super.leaveMethod(&transformer, outer_saved);
    try std.testing.expect(transformer.current_super_home_object == null);

    _ = try object_super.buildHomeProto(&transformer, first_method_home, parser.ast.getNode(producer_nodes[0]).span);
    _ = try object_super.buildHomeProto(&transformer, second_method_home, parser.ast.getNode(producer_nodes[1]).span);
    try std.testing.expectEqual(@as(usize, 2), transformer.object_super_home_references.items.len);
    try std.testing.expectEqual(producer_nodes[0], transformer.object_super_home_references.items[0].producer_node);
    try std.testing.expectEqual(producer_nodes[1], transformer.object_super_home_references.items[1].producer_node);
    object_super.release(&transformer, second_mark);
    try std.testing.expectEqual(@as(usize, 1), transformer.object_super_home_references.items.len);
    try std.testing.expectEqual(producer_nodes[0], transformer.object_super_home_references.items[0].producer_node);
    object_super.release(&transformer, mark);
    try std.testing.expectEqual(@as(usize, 0), transformer.object_super_home_references.items.len);
}

test "#6004 object-super home refs bind their producer nodes across ten hostile scopes" {
    const hostile_inputs = [_][]const u8{
        "function owner() { return { method() { return super.value; } }; }",
        "function owner() { function nested() { return { method() { return super.value; } }; } return nested(); }",
        "function* owner() { yield { method() { return super.value; } }; }",
        "async function owner() { await Promise.resolve({ method() { return super.value; } }); }",
        "function owner() { try { return { method() { return super.value; } }; } catch (error) { return { method() { return super.value + error; } }; } }",
        "function owner() { for (let index = 0; index < 1; index++) { const box = { method() { return super.value; } }; } }",
        "function owner() { switch (0) { case 0: return { method() { return super.value; } }; default: break; } }",
        "function owner() { const nested = () => ({ method() { return super.value; } }); return nested(); }",
        "function owner({ value } = { value: 7 }) { return { method() { return super.value + value; } }; }",
        "class Box { method() { function owner() { return { method() { return super.value; } }; } return owner(); } }",
    };
    for (hostile_inputs) |source| {
        try checkObjectSuperHomeReferenceHandle(source, .assign);
        try checkObjectSuperHomeReferenceHandle(source, .arrow);
        try checkObjectSuperHomeReferenceHandle(source, .function);
        try checkObjectSuperHomeReferenceHandle(source, .function_with_this);
    }
}
