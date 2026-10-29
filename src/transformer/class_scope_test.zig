const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Ast = @import("../parser/ast.zig").Ast;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const MethodExtra = @import("../parser/ast.zig").MethodExtra;
const Span = @import("../lexer/token.zig").Span;
const ast_walk = @import("../parser/ast_walk.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const coverage = @import("symbol_coverage.zig");
const es_helpers = @import("es_helpers.zig");
const Members = @import("es2015_class/members.zig").Members(Transformer);

fn expectAnonymousClassTempNameMarks(
    source: []const u8,
    use_define_for_class_fields: bool,
    expected_generated: usize,
    expected_late: usize,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = use_define_for_class_fields,
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
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
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
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    try std.testing.expect(report.isConsistent());
    try std.testing.expect(report.hasCompleteSymbolIdentity());

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);
    var generated_class_count: usize = 0;
    var late_name_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.kind != .class_decl or symbol.synthetic_name.len == 0) continue;
        generated_class_count += 1;
        if (symbol.synthetic_kind != .standalone_temp_binding) continue;
        late_name_count += 1;
        const id: u32 = @intCast(raw_id);
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqual(
            @as(?usize, raw_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );

        var bindings: usize = 0;
        var references: usize = 0;
        for (reachable) |raw_node| {
            if (raw_node >= edited.symbol_ids.len or edited.symbol_ids[raw_node] != id) continue;
            switch (transformer.ast.nodes.items[raw_node].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference => references += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expect(references > 0);
    }
    try std.testing.expectEqual(expected_generated, generated_class_count);
    try std.testing.expectEqual(expected_late, late_name_count);
}

test "#4819 anonymous class temp names finalize from their exact class SymbolIds" {
    // Both visitor modes create exact class bindings from makeTempVarSpan:
    // the private/static paths create the name early, while instance-private
    // lowering creates it when the class-expression wrapper is assembled.
    const source =
        \\var _a = 17;
        \\var PrivateStatic = class { static #value = 1; static read() { return this.#value; } };
        \\var StaticBlock = class { static { this.value = 2; } };
        \\var PrivateInstance = class { #value = 3; read() { return this.#value; } };
    ;
    try expectAnonymousClassTempNameMarks(source, true, 3, 3);
    try expectAnonymousClassTempNameMarks(source, false, 3, 3);
}

test "#4819 anonymous class temp names remain fixed when direct eval can see them" {
    const source =
        \\var Holder = class {
        \\  static #value = 1;
        \\  static read(suffix) { return eval("_" + suffix); }
        \\};
    ;
    try expectAnonymousClassTempNameMarks(source, true, 1, 0);
}

fn expectES5SuperNullishTempIdentity(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);
    const edited = (try transformer.finishSemanticEdit()).?;
    var exact_capture_found = false;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.kind != .variable_var or symbol.synthetic_name.len == 0) continue;
        const id: u32 = @intCast(raw_id);
        var reads: usize = 0;
        var writes: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id) continue;
            if (reference.flags.read) reads += 1;
            if (reference.flags.write) writes += 1;
            if (!reference.node_index.isNone())
                try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(reference.node_index)]);
        }
        if (reads != 1 or writes != 1) continue;

        var exact_bindings: usize = 0;
        for (reachable) |raw_node| {
            if (raw_node >= edited.symbol_ids.len or edited.symbol_ids[raw_node] != id) continue;
            if (transformer.ast.nodes.items[raw_node].tag == .binding_identifier) exact_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_bindings);
        exact_capture_found = true;
    }
    try std.testing.expect(exact_capture_found);
}

test "#4819 producer SymbolId attaches a super temp binding without its span registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const value = 1;");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var value_idx: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .numeric_literal) value_idx = @fromBackingInt(@intCast(raw));
    }
    const value = value_idx orelse return error.MissingCapturedValue;
    const value_span = parser.ast.getNode(value).span;
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = transformer.programScope();

    const captured = try es_helpers.captureToTempWithIdentity(&transformer, value, value_span);
    const symbol_id = captured.symbol_id orelse return error.MissingProducerSymbolId;
    const producer_counter = captured.temp_counter_index orelse return error.MissingProducerCounter;
    try std.testing.expectEqual(
        @as(?@TypeOf(symbol_id), symbol_id),
        if (transformer.temp_symbol_ids_by_counter.get(producer_counter)) |raw_id|
            @as(?@TypeOf(symbol_id), @fromBackingInt(raw_id))
        else
            null,
    );
    const editor = if (transformer.semantic_editor) |*semantic_editor| semantic_editor else return error.MissingSemanticEditor;
    const producer_symbol = editor.symbols.items[@backingInt(symbol_id)];
    try std.testing.expectEqual(.variable_var, producer_symbol.kind);
    try std.testing.expectEqual(transformer.current_scope, producer_symbol.scope_id);
    try std.testing.expectEqualStrings(transformer.ast.getText(captured.span), producer_symbol.synthetic_name);
    const assignment = transformer.ast.getNode(captured.paren_assign);
    const write = assignment.data.binary.left;
    try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), transformer.getSymbolIdAt(write));
    var exact_writes: usize = 0;
    for (editor.references.items) |reference| {
        if (reference.node_index != write) continue;
        try std.testing.expectEqual(symbol_id, reference.symbol_id);
        try std.testing.expectEqual(transformer.current_scope, reference.scope_id);
        try std.testing.expect(reference.flags.write);
        exact_writes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), exact_writes);
    const registry_key = (@as(u64, @backingInt(transformer.current_scope)) << 32) | captured.span.start;
    try std.testing.expect(transformer.synthetic_temp_symbol_ids.remove(registry_key));

    const binding = try transformer.createSyntheticTempBindingWithIdentity(
        captured.span,
        transformer.current_scope,
        symbol_id,
    );
    try std.testing.expect(!transformer.synthetic_temp_symbol_ids.contains(registry_key));
    try std.testing.expectEqual(symbol_id, binding.symbol_id.?);
    try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), transformer.getSymbolIdAt(binding.node));
    const read = try es_helpers.makeExactSyntheticRefAt(&transformer, binding.name_span, value_span);
    try transformer.addSyntheticRefInScope(read, symbol_id, transformer.current_scope, .{ .read = true });
    try std.testing.expectEqual(@as(?u32, @backingInt(symbol_id)), transformer.getSymbolIdAt(read));
}

test "#4819 ES5 super nullish producer identity survives ten hostile inputs" {
    const hostile_inputs = [_][]const u8{
        "class Base {} class Child extends Base { update(key) { return super[key] ??= 1; } }",
        "class Base {} class Child extends Base { update(log, key) { return super[(log.push('key'), key)] ??= (log.push('rhs'), 2); } }",
        "class Base {} class Child extends Base { update(key, use) { if (use) { { return super[key] ??= 3; } } return 0; } }",
        "class Base {} class Child extends Base { static update(key) { return super[key] ??= 4; } }",
        "class Base {} class Child extends Base { update(key) { const run = () => super[key] ??= 5; return run(); } }",
        "class Base {} class Child extends Base { update(key) { const run = () => { eval('typeof _a'); return super[key] ??= 6; }; return run(); } }",
        "class Base {} class Child extends Base { update(_a, key) { return super[key] ??= 7; } }",
        "class Base {} class Child extends Base { update() { return super['value'] ??= 8; } }",
        "class Base {} class Child extends Base { update(key, mode) { switch (mode) { case 1: return super[key] ??= 9; default: return 0; } } }",
        "class Base {} class Child extends Base { constructor(key) { super(); this.value = super[key] ??= 10; } }",
    };
    for (hostile_inputs) |source| try expectES5SuperNullishTempIdentity(source);
}

fn expectStage3ComputedKeyIdentityCase(expression: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = try std.fmt.allocPrint(allocator,
        \\const _a = 1, _b = 2, _c = 3;
        \\function dec(value, context) {{ return value; }}
        \\function nextKey() {{ return "computed"; }}
        \\const holder = {{ key() {{ return nextKey(); }}, value: "value" }};
        \\const dynamic = "dynamic", suffix = "suffix", fallback = "fallback";
        \\class Box {{
        \\  @dec [{s}]() {{ return 1; }}
        \\  @dec [{s}] = 2;
        \\  @dec accessor [{s}] = 3;
        \\}}
    , .{ expression, expression, expression });

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);

    try std.testing.expectEqual(@as(usize, 3), transformer.temp_symbol_ids_by_counter.count());
    var metadata_scope: ?@import("../semantic/scope.zig").ScopeId = null;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_metadata")) continue;
        if (raw >= edited.symbol_ids.len) return error.MissingStage3MetadataBindingId;
        const id = edited.symbol_ids[raw] orelse return error.MissingStage3MetadataBindingId;
        const scope = edited.symbols.items[id].scope_id;
        if (metadata_scope) |previous| {
            try std.testing.expectEqual(previous, scope);
        } else {
            metadata_scope = scope;
        }
    }
    const exact_metadata_scope = metadata_scope orelse return error.MissingStage3MetadataScope;
    try std.testing.expectEqual(.class_static_block, edited.scopes[exact_metadata_scope.toIndex()].kind);
    try std.testing.expect(edited.scopes[exact_metadata_scope.toIndex()].is_strict);
    var metadata_owners: usize = 0;
    for (reachable) |raw| {
        const candidate = transformer.ast.nodes.items[raw];
        if (candidate.tag != .static_block or edited.scope_owner_map.get(raw) != @backingInt(exact_metadata_scope)) continue;
        try std.testing.expectEqual(@as(?u32, @backingInt(exact_metadata_scope)), edited.scope_owner_map.get(@backingInt(candidate.data.unary.operand)));
        metadata_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), metadata_owners);
    var producers = transformer.temp_symbol_ids_by_counter.iterator();
    var saw_three_reads = false;
    var saw_four_reads = false;
    var saw_five_reads = false;
    while (producers.next()) |entry| {
        const id = entry.value_ptr.*;
        const symbol = edited.symbols.items[id];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);

        // The producer registry is intentionally removed as soon as the
        // exact handle is carried out of key creation. Consumers succeeding
        // here cannot be relying on a span/scope re-lookup.
        var registered = transformer.synthetic_temp_symbol_ids.valueIterator();
        while (registered.next()) |registered_id| try std.testing.expect(registered_id.* != id);

        var bindings: usize = 0;
        for (reachable) |raw| {
            if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != id) continue;
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier) bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);

        var reads: usize = 0;
        var function_reads: usize = 0;
        var block_reads: usize = 0;
        var outer_reads: usize = 0;
        var writes: usize = 0;
        var declarations: usize = 0;
        var writer_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        var metadata_read_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id) continue;
            if (reference.flags.declare) {
                try std.testing.expect(reference.node_index.isNone());
                try std.testing.expectEqual(symbol.scope_id, reference.scope_id);
                declarations += 1;
                continue;
            }
            if (reference.node_index.isNone() or @backingInt(reference.node_index) >= edited.symbol_ids.len)
                return error.MissingStage3KeyReferenceNode;
            try std.testing.expectEqual(@as(?u32, id), edited.symbol_ids[@backingInt(reference.node_index)]);

            var scope = reference.scope_id;
            var visible_from_reference = false;
            var hops: usize = 0;
            while (!scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (scope == symbol.scope_id) {
                    visible_from_reference = true;
                    break;
                }
                scope = edited.scopes[scope.toIndex()].parent;
            }
            try std.testing.expect(visible_from_reference);

            if (reference.flags.write) {
                try std.testing.expect(!reference.flags.read);
                writes += 1;
                writer_scope = reference.scope_id;
                continue;
            }
            try std.testing.expect(reference.flags.read);
            reads += 1;
            switch (edited.scopes[reference.scope_id.toIndex()].kind) {
                .function => {
                    function_reads += 1;
                    const parent = edited.scopes[reference.scope_id.toIndex()].parent;
                    try std.testing.expect(!parent.isNone());
                    try std.testing.expectEqual(exact_metadata_scope, parent);
                },
                .class_static_block => {
                    try std.testing.expectEqual(exact_metadata_scope, reference.scope_id);
                    block_reads += 1;
                    metadata_read_scope = reference.scope_id;
                },
                else => outer_reads += 1,
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expectEqual(@as(usize, 1), writes);
        try std.testing.expect(metadata_read_scope != null);
        try std.testing.expect(writer_scope != null);
        try std.testing.expect(metadata_read_scope.? != writer_scope.?);
        try std.testing.expectEqual(@as(usize, 1), block_reads); // context.name
        switch (reads) {
            3 => {
                try std.testing.expectEqual(@as(usize, 2), function_reads);
                try std.testing.expectEqual(@as(usize, 0), outer_reads);
                saw_three_reads = true;
            },
            4 => {
                try std.testing.expectEqual(@as(usize, 3), function_reads);
                try std.testing.expectEqual(@as(usize, 0), outer_reads);
                saw_four_reads = true;
            },
            5 => {
                try std.testing.expectEqual(@as(usize, 3), function_reads);
                try std.testing.expectEqual(@as(usize, 1), outer_reads); // generated accessor setter key
                saw_five_reads = true;
            },
            else => return error.UnexpectedStage3KeyReadCount,
        }
    }
    try std.testing.expect(saw_three_reads and saw_four_reads and saw_five_reads);
}

test "#4819 Stage 3 computed decorator keys carry exact identities through all consumers" {
    const hostile_expressions = [_][]const u8{
        "nextKey()",
        "holder.key()",
        "holder.value + nextKey()",
        "(nextKey(), holder.value)",
        "`${nextKey()}-${suffix}`",
        "Symbol.for(nextKey())",
        "nextKey()?.name ?? fallback",
        "((value) => holder[value])(nextKey())",
        "eval('nextKey()')",
        "(() => holder[dynamic])()",
    };
    for (hostile_expressions) |expression| try expectStage3ComputedKeyIdentityCase(expression);
}

test "#4819 ES5 computed super assignment and update temps have exact identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base { get value() { return 1; } set value(next) {} }
        \\class Child extends Base {
        \\  compound(key, delta) { return super[key] += delta; }
        \\  postfix(key) { return super[key]++; }
        \\  nullish(key) { return super[key] ??= 5; }
        \\  *sequence() { yield super[key] += 1; yield super[key]++; yield super[key] ??= 8; }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    try std.testing.expect(transformer.generator_state_temp_refs.items.len > 0);
    for (transformer.generator_state_temp_refs.items) |pending| {
        for (transformer.pending_temp_refs.items) |by_name| {
            try std.testing.expect(by_name.node != pending.reference);
        }
    }
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);
    var live_exact_refs: usize = 0;
    for (transformer.generator_state_temp_refs.items) |pending| {
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(pending.binding)) != null);
        if (std.mem.indexOfScalar(u32, reachable, @backingInt(pending.reference)) == null) continue;
        const binding_id = transformer.getSymbolIdAt(pending.binding) orelse return error.MissingSuperTempSymbol;
        try std.testing.expectEqual(@as(?u32, binding_id), transformer.getSymbolIdAt(pending.reference));
        live_exact_refs += 1;
    }
    try std.testing.expect(live_exact_refs > 0);
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
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        &analyzer.unresolved_references,
    );
    defer report.deinit(allocator);

    var exact_temp_findings: usize = 0;
    for (report.findings.items) |finding| {
        if (!finding.marked_synthetic or
            (!std.mem.eql(u8, finding.name, "_a") and !std.mem.eql(u8, finding.name, "_b"))) continue;
        exact_temp_findings += 1;
        try std.testing.expectEqual(coverage.StrictStatus.bound, finding.status);
    }
    try std.testing.expect(exact_temp_findings >= 5);
}

fn expectES5SuperPropertyTempProducerIdentity(source: []const u8, operation: []const u8, expect_block_scope: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var operation_span: ?Span = null;
    for (parser.ast.nodes.items) |node| {
        if (!std.mem.eql(u8, parser.ast.getText(node.span), operation)) continue;
        operation_span = node.span;
        break;
    }
    const expected_operation_span = operation_span orelse return error.MissingSuperPropertyOperation;

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    var expected_reference_scope: ?ScopeId = null;
    var smallest_block_span: usize = std.math.maxInt(usize);
    if (expect_block_scope) {
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .block_statement or
                node.span.start > expected_operation_span.start or node.span.end < expected_operation_span.end)
                continue;
            const scope_raw = analyzer.scope_owner_map.get(@intCast(raw)) orelse continue;
            const span_len = node.span.end - node.span.start;
            if (span_len >= smallest_block_span) continue;
            expected_reference_scope = @fromBackingInt(scope_raw);
            smallest_block_span = span_len;
        }
    }
    if (expect_block_scope and expected_reference_scope == null) return error.MissingNestedSuperPropertyScope;
    const source_symbol_count = analyzer.symbols.items.len;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const root = try transformer.transform();
    if (expected_reference_scope) |scope|
        try std.testing.expect(scope != transformer.nearestVarScope(scope));
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const SymbolId = @import("../semantic/symbol.zig").SymbolId;
    var matching_bindings: usize = 0;
    for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, raw_id| {
        if (symbol.kind != .variable_var or
            symbol.declaration_span.start != expected_operation_span.start or
            symbol.declaration_span.end != expected_operation_span.end)
            continue;

        const id: SymbolId = @fromBackingInt(@intCast(@as(u32, @intCast(raw_id))));
        // The producer is created with a known owner, so references and the
        // later hoisted declaration must share the producer-map identity. The
        // span/scope registry must not be the source of that identity.
        var producer_matches: usize = 0;
        var producer_id: ?u64 = null;
        var producers = transformer.temp_symbols_by_producer_id.iterator();
        while (producers.next()) |entry| {
            if (entry.value_ptr.* != raw_id) continue;
            producer_id = entry.key_ptr.*;
            producer_matches += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), producer_matches);
        const exact_producer_id = producer_id orelse return error.MissingSuperPropertyProducerId;
        try std.testing.expect(transformer.lookupSyntheticTempSymbol(symbol.name, symbol.scope_id) == null);

        var matching_slots: usize = 0;
        var slots = transformer.temp_symbol_ids_by_counter.iterator();
        while (slots.next()) |slot| {
            if (slot.value_ptr.* != raw_id) continue;
            const slot_producer_id = transformer.temp_producer_id_by_counter.get(slot.key_ptr.*) orelse continue;
            const slot_span = transformer.temp_span_by_counter.get(slot.key_ptr.*) orelse continue;
            if (slot_producer_id != exact_producer_id or
                slot_span.start != symbol.name.start or slot_span.end != symbol.name.end)
                continue;
            matching_slots += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), matching_slots);

        var read_count: usize = 0;
        var write_count: usize = 0;
        for (editor.references.items) |reference| {
            if (reference.symbol_id != id or reference.node_index.isNone()) continue;
            try std.testing.expect(editor.symbolVisibleFrom(id, reference.scope_id));
            try std.testing.expectEqual(symbol.scope_id, transformer.nearestVarScope(reference.scope_id));
            if (expected_reference_scope) |expected_scope|
                try std.testing.expectEqual(expected_scope, reference.scope_id);
            const ref_node = transformer.ast.getNode(reference.node_index);
            try std.testing.expect(ref_node.tag == .identifier_reference or ref_node.tag == .assignment_target_identifier);
            try std.testing.expectEqual(symbol.name.start, ref_node.data.string_ref.start);
            try std.testing.expectEqual(symbol.name.end, ref_node.data.string_ref.end);
            if (reference.flags.read) read_count += 1;
            if (reference.flags.write) write_count += 1;
        }
        try std.testing.expect(read_count + write_count > 0);
        matching_bindings += 1;
    }
    try std.testing.expect(matching_bindings > 0);

    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);
    for (reachable) |raw| {
        if (raw >= edited.symbol_ids.len) continue;
        const id = edited.symbol_ids[raw] orelse continue;
        if (transformer.ast.nodes.items[raw].tag != .identifier_reference and
            transformer.ast.nodes.items[raw].tag != .assignment_target_identifier)
            continue;
        const node_index: NodeIndex = @fromBackingInt(@intCast(raw));
        for (edited.references) |reference| {
            if (reference.node_index != node_index) continue;
            try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
        }
    }
}

test "#4819 ES5 computed super-property temps stay attached to their allocator producer IDs" {
    const cases = [_]struct { source: []const u8, operation: []const u8, expect_block_scope: bool = false }{
        .{ .source = "class Base {} class Child extends Base { method(key, delta) { return super[key] += delta; } }", .operation = "super[key] += delta" },
        .{ .source = "class Base {} class Child extends Base { method(key, delta) { return super[key] -= delta; } }", .operation = "super[key] -= delta" },
        .{ .source = "class Base {} class Child extends Base { method(key, delta) { return super[key] *= delta; } }", .operation = "super[key] *= delta" },
        .{ .source = "class Base {} class Child extends Base { method(key, delta) { return super[key] |= delta; } }", .operation = "super[key] |= delta" },
        .{ .source = "class Base {} class Child extends Base { method(key, rhs) { return super[key] &&= rhs; } }", .operation = "super[key] &&= rhs" },
        .{ .source = "class Base {} class Child extends Base { method(key, rhs) { return super[key] ||= rhs; } }", .operation = "super[key] ||= rhs" },
        .{ .source = "class Base {} class Child extends Base { method(key) { return super[key]++; } }", .operation = "super[key]++" },
        .{ .source = "class Base {} class Child extends Base { method(key) { return super[key]--; } }", .operation = "super[key]--" },
        .{ .source = "class Base {} class Child extends Base { method(key, delta, log) { eval('typeof _a'); return super[(log.push('key'), key)] += delta; } }", .operation = "super[(log.push('key'), key)] += delta" },
        .{ .source = "class Base {} class Child extends Base { static method(key, delta) { const read = () => eval('typeof _b'); return super[Symbol.for(key)] += delta; } }", .operation = "super[Symbol.for(key)] += delta" },
        .{ .source = "class Base {} class Child extends Base { method(key, delta) { const nested = () => super[key] += delta; return nested(); } }", .operation = "super[key] += delta" },
        .{ .source = "class Base {} class Child extends Base { method(key, delta) { if (key) { return super[key] += delta; } return 0; } }", .operation = "super[key] += delta", .expect_block_scope = true },
    };
    for (cases) |case| try expectES5SuperPropertyTempProducerIdentity(case.source, case.operation, case.expect_block_scope);
}

test "#4819 reused super-temp allocator slots keep distinct producer identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const seed = 1;");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    const no_node = @backingInt(NodeIndex.none);
    const empty_list = try transformer.ast.addNodeList(&.{});
    const params = try transformer.ast.addFormalParameters(empty_list, .EMPTY);
    const body = try transformer.ast.addNode(.{
        .tag = .block_statement,
        .span = .EMPTY,
        .data = .{ .list = empty_list },
    });
    const extra = try transformer.ast.addExtras(&.{ no_node, @backingInt(params), @backingInt(body), 0, no_node });
    const first_owner = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = extra },
    });
    const second_owner = try transformer.ast.addNode(.{
        .tag = .function_expression,
        .span = .EMPTY,
        .data = .{ .extra = extra },
    });
    const program_scope = transformer.programScope();
    const first_scope = try transformer.addGeneratedFunctionScope(program_scope, first_owner);
    const second_scope = try transformer.addGeneratedFunctionScope(program_scope, second_owner);
    try std.testing.expect(first_scope != second_scope);

    const saved_temp_counter = transformer.temp_var_counter;
    transformer.current_scope = first_scope;
    const first_span = try es_helpers.makeTempVarSpan(&transformer);
    const first_counter = transformer.temp_var_counter - 1;
    const first_producer = transformer.temp_producer_id_by_counter.get(first_counter) orelse
        return error.MissingFirstSuperTempProducer;
    const first_id = (try transformer.reserveSyntheticTempSymbolForProducerInScope(
        first_producer,
        first_span,
        .EMPTY,
        first_scope,
    )) orelse return error.MissingFirstSuperTempSymbol;
    const first_binding = try transformer.createSyntheticTempBindingWithIdentity(first_span, first_scope, first_id);
    try std.testing.expectEqual(first_id, first_binding.symbol_id.?);
    try transformer.temp_symbol_ids_by_counter.put(allocator, first_counter, @backingInt(first_id));
    const first_reference = try es_helpers.makeExactSyntheticRefAt(&transformer, first_span, .EMPTY);
    try transformer.addSyntheticRefInScope(first_reference, first_id, first_scope, .{ .read = true });

    // Match the class lowerer's saved-counter restoration before a later owner
    // allocates again at slot zero. The generated spelling interns to the same
    // Span, while the allocator must issue a new producer handle.
    transformer.temp_var_counter = saved_temp_counter;
    transformer.current_scope = second_scope;
    _ = try es_helpers.makeTempVarSpan(&transformer);
    const second_counter = transformer.temp_var_counter - 1;
    const second_producer = transformer.temp_producer_id_by_counter.get(second_counter) orelse
        return error.MissingSecondSuperTempProducer;
    // Force the restored allocator slot to alias the first interned spelling
    // under another owner scope. The second producer still needs its own ID.
    try transformer.temp_span_by_counter.put(allocator, second_counter, first_span);
    const second_span = first_span;
    const second_id = (try transformer.reserveSyntheticTempSymbolForProducerInScope(
        second_producer,
        second_span,
        .EMPTY,
        second_scope,
    )) orelse return error.MissingSecondSuperTempSymbol;
    const second_binding = try transformer.createSyntheticTempBindingWithIdentity(second_span, second_scope, second_id);
    try std.testing.expectEqual(second_id, second_binding.symbol_id.?);
    try transformer.temp_symbol_ids_by_counter.put(allocator, second_counter, @backingInt(second_id));
    const second_reference = try es_helpers.makeExactSyntheticRefAt(&transformer, second_span, .EMPTY);
    try transformer.addSyntheticRefInScope(second_reference, second_id, second_scope, .{ .read = true });

    try std.testing.expectEqual(first_counter, second_counter);
    try std.testing.expectEqual(first_span.start, second_span.start);
    try std.testing.expectEqual(first_span.end, second_span.end);
    try std.testing.expect(first_producer != second_producer);
    try std.testing.expect(first_id != second_id);
    try std.testing.expectEqual(@as(?u32, @backingInt(first_id)), transformer.temp_symbols_by_producer_id.get(first_producer));
    try std.testing.expectEqual(@as(?u32, @backingInt(second_id)), transformer.temp_symbols_by_producer_id.get(second_producer));
    try std.testing.expectEqual(@as(?u64, second_producer), transformer.temp_producer_id_by_counter.get(second_counter));
    try std.testing.expectEqual(@as(?u32, @backingInt(second_id)), transformer.temp_symbol_ids_by_counter.get(second_counter));
    try std.testing.expect(transformer.lookupSyntheticTempSymbol(first_span, first_scope) == null);
    try std.testing.expect(transformer.lookupSyntheticTempSymbol(second_span, second_scope) == null);

    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const first_record = (try editor.referenceForNode(first_reference)) orelse return error.MissingFirstSuperTempReference;
    const second_record = (try editor.referenceForNode(second_reference)) orelse return error.MissingSecondSuperTempReference;
    try std.testing.expectEqual(first_id, first_record.symbol_id);
    try std.testing.expectEqual(second_id, second_record.symbol_id);
    try std.testing.expectEqual(first_scope, first_record.scope_id);
    try std.testing.expectEqual(second_scope, second_record.scope_id);
    try std.testing.expect(editor.symbolVisibleFrom(first_id, first_record.scope_id));
    try std.testing.expect(editor.symbolVisibleFrom(second_id, second_record.scope_id));
}

test "#4819 lexical this captures receive late names through exact SymbolIds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\var _this = "outer";
        \\class Base { constructor() { this.value = 5; } }
        \\class Explicit extends Base {
        \\  read = () => this.value;
        \\  constructor() { super(); }
        \\}
        \\class Default extends Base { read = () => this.value; }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    const capture_kind = @import("../semantic/symbol.zig").SyntheticKind.this_capture_binding;
    var capture_ids: [2]u32 = undefined;
    var capture_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var capture_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != capture_kind) continue;
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqualStrings(
            "_this",
            transformer.late_output_name_bases.get(symbol.synthetic_name) orelse return error.MissingLateThisBaseName,
        );
        try std.testing.expect(capture_count < capture_ids.len);
        capture_ids[capture_count] = @intCast(raw_id);
        capture_scopes[capture_count] = symbol.scope_id;
        capture_count += 1;

        const symbol_id: u32 = @intCast(raw_id);
        try std.testing.expectEqual(
            @as(?usize, symbol_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );
        var declaration_count: usize = 0;
        var reference_count: usize = 0;
        for (reachable) |raw| {
            if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != symbol_id) continue;
            const tag = transformer.ast.nodes.items[raw].tag;
            if (tag == .binding_identifier) declaration_count += 1;
            if (tag == .identifier_reference) reference_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), declaration_count);
        try std.testing.expect(reference_count > 0);
    }
    try std.testing.expectEqual(@as(usize, 2), capture_count);
    try std.testing.expect(capture_ids[0] != capture_ids[1]);
    try std.testing.expect(capture_scopes[0] != capture_scopes[1]);
}

test "#4819 lexical arguments captures receive late names through exact SymbolIds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\var _arguments = "outer";
        \\class Base {}
        \\class Derived extends Base {
        \\  constructor(value = (() => arguments.length)()) { super(); this.value = value; }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    const capture_kind = @import("../semantic/symbol.zig").SyntheticKind.arguments_capture_binding;
    var capture_id: ?u32 = null;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != capture_kind) continue;
        try std.testing.expect(capture_id == null);
        capture_id = @intCast(raw_id);
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqualStrings(
            "_arguments",
            transformer.late_output_name_bases.get(symbol.synthetic_name) orelse return error.MissingLateArgumentsBaseName,
        );
        try std.testing.expectEqual(
            @as(?usize, raw_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );
    }
    const exact_id = capture_id orelse return error.MissingLateArgumentsCapture;
    var declaration_count: usize = 0;
    var reference_count: usize = 0;
    for (reachable) |raw| {
        if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != exact_id) continue;
        const tag = transformer.ast.nodes.items[raw].tag;
        if (tag == .binding_identifier) declaration_count += 1;
        if (tag == .identifier_reference) reference_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), declaration_count);
    try std.testing.expect(reference_count > 0);
}

test "#4819 class field computed-key prehoist binds temp identity exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const key = "value";
        \\class Box {
        \\  static [key] = Box;
        \\  field = Box;
        \\}
        \\class InstanceBox {
        \\  [key] = 1;
        \\}
        \\class MethodBox {
        \\  [key]() { return this; }
        \\  field = 1;
        \\}
        \\class AccessorMethodBox {
        \\  get [key]() { return 1; }
        \\  field = 2;
        \\}
        \\class StaticMethodBox {
        \\  static [key]() { return this; }
        \\  field = 3;
        \\}
        \\const ExpressionBox = class {
        \\  static [key] = 1;
        \\  [key]() { return this; }
        \\  field = 2;
        \\};
        \\const SimpleExpressionBox = class {
        \\  [key] = 3;
        \\};
        \\function makeNested(_a) {
        \\  const nestedKey = "nested";
        \\  class NestedBox {
        \\    static [nestedKey] = NestedBox;
        \\    [nestedKey] = 1;
        \\  }
        \\  return NestedBox;
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
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
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("class-computed-field-prehoist-es5.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "#4819 class computed-key memo binds only its producer reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const key = 'value'; key;");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    const source_symbol_count = analyzer.symbols.items.len;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    var key_reference: NodeIndex = .none;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "key")) continue;
        key_reference = @fromBackingInt(@intCast(raw));
        break;
    }
    if (key_reference.isNone()) return error.MissingComputedKeyReference;

    const none = @backingInt(NodeIndex.none);
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
    transformer.current_scope = transformer.programScope();

    const memo = try es_helpers.memoizeComputedKey(&transformer, key_reference, .EMPTY, false);
    var classified = Members.ClassifiedMembers{
        .constructor_idx = null,
        .methods = .empty,
        .instance_fields = .empty,
        .static_elements = .empty,
        .accessors = .empty,
        .private_fields = .empty,
        .static_private_fields = .empty,
        .private_methods = .empty,
    };
    defer classified.deinit(allocator);
    try classified.computed_key_temp_bindings.append(allocator, memo);

    // Reuse the allocator slot so a distinct producer receives the same
    // interned spelling span. Force this alias to cover interning and slot
    // restoration behavior independently of the AST string-table strategy.
    transformer.temp_var_counter = 0;
    _ = try es_helpers.makeTempVarSpan(&transformer);
    const decoy_producer_id = transformer.temp_producer_id_by_counter.get(0) orelse
        return error.MissingDecoyProducerId;
    try std.testing.expect(decoy_producer_id != memo.temp_producer_id.?);
    try transformer.temp_span_by_counter.put(allocator, 0, memo.temp_span);
    const decoy_span = transformer.temp_span_by_counter.get(0) orelse return error.MissingDecoySpan;
    try std.testing.expectEqual(memo.temp_span.start, decoy_span.start);
    try std.testing.expectEqual(memo.temp_span.end, decoy_span.end);
    const decoy = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, memo.temp_span);
    try transformer.trackHoistedTempRefByProducerIdInScope(
        decoy_producer_id,
        memo.temp_span,
        decoy,
        owner_scope,
        .{ .read = true },
    );
    try Members.bindComputedKeyTemps(&transformer, &classified, owner_scope, .EMPTY);

    const id_raw = transformer.getSymbolIdAt(memo.binding) orelse return error.MissingComputedKeyTempSymbol;
    try std.testing.expectEqual(@as(?u32, id_raw), transformer.getSymbolIdAt(memo.computed_ref));
    try std.testing.expect(transformer.getSymbolIdAt(decoy) == null);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(@as(usize, 1), transformer.pending_temp_producer_refs.items.len);
    try std.testing.expectEqual(decoy_producer_id, transformer.pending_temp_producer_refs.items[0].temp_producer_id);
    try std.testing.expectEqual(decoy, transformer.pending_temp_producer_refs.items[0].node);

    const editor = if (transformer.semantic_editor) |*value| value else return error.TestUnexpectedResult;
    const reference_record = (try editor.referenceForNode(memo.computed_ref)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(@import("../semantic/symbol.zig").SymbolId, @fromBackingInt(@intCast(id_raw))), reference_record.symbol_id);
    try std.testing.expectEqual(owner_scope, reference_record.scope_id);
    try std.testing.expect((try editor.referenceForNode(decoy)) == null);
    try std.testing.expectEqual(source_symbol_count + 1, editor.symbols.items.len);
}

test "#4819 class computed-key handoff keeps a deferred producer handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const key = 'value'; key;");
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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const program_scope = transformer.programScope();
    transformer.current_scope = program_scope;

    var key_reference: NodeIndex = .none;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "key")) continue;
        key_reference = @fromBackingInt(@intCast(raw));
        break;
    }
    if (key_reference.isNone()) return error.MissingComputedKeyReference;

    const none = @backingInt(NodeIndex.none);
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
    const owner_scope = try transformer.addGeneratedFunctionScope(program_scope, owner);

    transformer.state_machine_depth = 1;
    const capture = try es_helpers.captureToTrackedTemp(&transformer, key_reference, .EMPTY);
    try std.testing.expect(capture.symbol_id == null);
    const producer_id = capture.temp_producer_id orelse return error.MissingTempProducerHandle;
    const read = try es_helpers.makeCapturedTempRef(&transformer, capture, .EMPTY, .{ .read = true });
    transformer.state_machine_depth = 0;

    var classified = Members.ClassifiedMembers{
        .constructor_idx = null,
        .methods = .empty,
        .instance_fields = .empty,
        .static_elements = .empty,
        .accessors = .empty,
        .private_fields = .empty,
        .static_private_fields = .empty,
        .private_methods = .empty,
    };
    defer classified.deinit(allocator);
    try classified.computed_key_temp_reads.append(allocator, read);
    const decoy = try es_helpers.makeExactSyntheticRefFromSpan(&transformer, capture.span);
    try classified.computed_key_temp_reads.append(allocator, decoy);

    // The owner link must survive without the temp-name span indexes.
    transformer.temp_span_by_counter.clearRetainingCapacity();
    transformer.temp_symbol_ids_by_counter.clearRetainingCapacity();
    try Members.bindComputedKeyTemps(&transformer, &classified, owner_scope, .EMPTY);

    const binding = try es_helpers.makeSyntheticBinding(&transformer, capture.span);
    try transformer.bindHoistedTempWithProducerIdentity(
        binding,
        capture.span,
        .EMPTY,
        program_scope,
        null,
        producer_id,
    );

    const symbol_id = transformer.getSymbolIdAt(binding) orelse return error.MissingTempBindingSymbol;
    try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(read));
    try std.testing.expect(transformer.getSymbolIdAt(decoy) == null);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    const reference = (try editor.referenceForNode(read)) orelse return error.MissingComputedKeyReferenceRecord;
    try std.testing.expectEqual(@as(@import("../semantic/symbol.zig").SymbolId, @fromBackingInt(@intCast(symbol_id))), reference.symbol_id);
    try std.testing.expectEqual(owner_scope, reference.scope_id);
    try std.testing.expect(reference.flags.read);
    try std.testing.expect(!reference.flags.write);
    try std.testing.expect((try editor.referenceForNode(decoy)) == null);
    const write = transformer.ast.getNode(capture.paren_assign).data.binary.left;
    try std.testing.expectEqual(@as(?u32, symbol_id), transformer.getSymbolIdAt(write));
    const write_reference = (try editor.referenceForNode(write)) orelse return error.MissingCapturedTempWrite;
    try std.testing.expectEqual(program_scope, write_reference.scope_id);
    try std.testing.expect(write_reference.flags.write);
    try std.testing.expect(!write_reference.flags.read);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_refs.items.len);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_producer_refs.items.len);
}

test "#4819 static-block computed-key memo owns an exact producer identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(
        allocator,
        "const key = 'value'; class Box { static [key]() { return 1; } static { this.ready = true; } } const Expression = class Expression { static [key]() { return 2; } static { this.ready = true; } };",
    );
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
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
    transformer.semantic_edit_enabled = true;

    const root = try transformer.transform();
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    defer allocator.free(reachable);
    const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
    var expected_memo_scopes: std.ArrayList(@import("../semantic/scope.zig").ScopeId) = .empty;
    defer expected_memo_scopes.deinit(allocator);
    for (0..transformer.parser_node_count) |source_raw| {
        const source_class = transformer.ast.nodes.items[source_raw];
        if (source_class.tag != .class_declaration and source_class.tag != .class_expression) continue;
        const body_idx = transformer.ast.readExtraNode(source_class.data.extra, @import("../parser/ast.zig").ClassExtra.body);
        if (body_idx.isNone() or transformer.ast.getNode(body_idx).tag != .class_body) continue;
        const body = transformer.ast.getNode(body_idx).data.list;
        var has_static_block = false;
        var has_computed_method = false;
        for (transformer.ast.extra_data.items[body.start .. body.start + body.len]) |member_raw| {
            const member = transformer.ast.getNode(@fromBackingInt(@intCast(member_raw)));
            if (member.tag == .static_block) has_static_block = true;
            if (member.tag == .method_definition) {
                const key = transformer.ast.readExtraNode(member.data.extra, MethodExtra.key);
                if (!key.isNone() and transformer.ast.getNode(key).tag == .computed_property_key) has_computed_method = true;
            }
        }
        if (!has_static_block or !has_computed_method) continue;
        const source_idx: NodeIndex = @fromBackingInt(@intCast(source_raw));
        const class_scope = transformer.outputOwnedScope(source_idx) orelse return error.MissingOutputClassScope;
        const emitted_scope = transformer.outputScopeParent(class_scope);
        try expected_memo_scopes.append(allocator, transformer.nearestVarScope(emitted_scope));
    }
    try std.testing.expectEqual(@as(usize, 2), expected_memo_scopes.items.len);
    var memos_found: usize = 0;
    for (reachable) |raw| {
        const declarator = transformer.ast.nodes.items[raw];
        if (declarator.tag != .variable_declarator) continue;
        const init = transformer.ast.readExtraNode(declarator.data.extra, 2);
        if (init.isNone() or transformer.ast.getNode(init).tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(init).data.string_ref), "key")) continue;
        const memo_binding = transformer.ast.readExtraNode(declarator.data.extra, 0);
        const memo_name = transformer.ast.getText(transformer.ast.getNode(memo_binding).data.string_ref);
        const memo_id = transformer.getSymbolIdAt(memo_binding) orelse return error.MissingStaticBlockComputedKeyMemoSymbol;
        const symbol = editor.symbols.items[memo_id];
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqual(expected_memo_scopes.items[memos_found], symbol.scope_id);

        var exact_key_refs: usize = 0;
        for (reachable) |key_raw| {
            const key = transformer.ast.nodes.items[key_raw];
            if (key.tag != .computed_property_key) continue;
            const ref = key.data.unary.operand;
            if (ref.isNone() or transformer.ast.getNode(ref).tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(ref).data.string_ref), memo_name)) continue;
            try std.testing.expectEqual(@as(?u32, memo_id), transformer.getSymbolIdAt(ref));
            const record = (try editor.referenceForNode(ref)) orelse return error.MissingStaticBlockComputedKeyReference;
            try std.testing.expectEqual(memo_id, @backingInt(record.symbol_id));
            try std.testing.expect(record.flags.read);
            try std.testing.expect(!record.flags.write);
            try std.testing.expectEqual(symbol.scope_id, transformer.nearestVarScope(record.scope_id));
            exact_key_refs += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), exact_key_refs);
        memos_found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), memos_found);
}

test "#4819 anonymous private class wrapper owns its generated name exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base { constructor(public value: number) {} }
        \\function create(_args: number) {
        \\  return class extends Base {
        \\    #hidden = 1;
        \\    amount: number = _args;
        \\  };
        \\}
        \\function createStatic() {
        \\  return class extends Base {
        \\    static #hidden = 1;
        \\    static read() { return this.#hidden; }
        \\  };
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = false,
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
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
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
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("anonymous-private-class-wrapper-es2015.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());

    var binding_ids: std.ArrayList(u32) = .empty;
    defer binding_ids.deinit(allocator);
    var reference_ids: std.ArrayList(u32) = .empty;
    defer reference_ids.deinit(allocator);
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_a")) continue;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (node.tag == .binding_identifier) {
            try binding_ids.append(allocator, id);
        } else {
            try reference_ids.append(allocator, id);
        }
    }
    // Each class wrapper owns one class-name binding; its name must not also
    // be hoisted into the surrounding function as an unrelated `var _a`.
    try std.testing.expectEqual(@as(usize, 2), binding_ids.items.len);
    try std.testing.expect(binding_ids.items[0] != binding_ids.items[1]);
    try std.testing.expect(reference_ids.items.len >= 2);
    for (reference_ids.items) |reference_id| {
        try std.testing.expect(reference_id == binding_ids.items[0] or reference_id == binding_ids.items[1]);
    }
    var generated_class_self_count: usize = 0;
    var self_iter = transformer.class_self_symbol_map.iterator();
    while (self_iter.next()) |entry| {
        const name = transformer.ast.getText(edited.symbols.items[entry.value_ptr.*].name);
        if (!std.mem.eql(u8, name, "_a")) continue;
        generated_class_self_count += 1;
        try std.testing.expect(entry.value_ptr.* == binding_ids.items[0] or entry.value_ptr.* == binding_ids.items[1]);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_class_self_count);
}

test "#4819 ES5 class inner write keeps source IDs and binds accessor uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\let Outer = class Inner { constructor(Inner) { this.arg = Inner; } static write() { Inner = 3; } static self() { return Inner; } };
        \\class Declared { constructor(Declared) { this.arg = Declared; } static write() { Declared++; } static self() { return Declared; } }
        \\Outer = Declared;
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var expression_inner: ?u32 = null;
    var declaration_inner: ?u32 = null;
    var declaration_outer: ?u32 = null;
    var parameter_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) expression_inner = analyzer.class_self_symbol_map.get(@intCast(raw));
        if (node.tag == .class_declaration) {
            declaration_inner = analyzer.class_self_symbol_map.get(@intCast(raw));
            const name_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").ClassExtra.name];
            declaration_outer = analyzer.symbol_ids.items[name_raw];
        }
    }
    const expr_id = expression_inner orelse return error.TestUnexpectedResult;
    const decl_id = declaration_inner orelse return error.TestUnexpectedResult;
    const outer_id = declaration_outer orelse return error.TestUnexpectedResult;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "Inner")) continue;
        const id = analyzer.symbol_ids.items[raw] orelse continue;
        if (id != expr_id) parameter_id = id;
    }
    const param_id = parameter_id orelse return error.TestUnexpectedResult;
    try std.testing.expect(expr_id != param_id);
    try std.testing.expect(decl_id != outer_id);

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var found_expr_storage = false;
    var found_decl_storage = false;
    var found_outer = false;
    var found_param = false;
    var accessor_refs: usize = 0;
    for (reachable) |raw| {
        if (raw >= edited.symbol_ids.len or transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
        const id = edited.symbol_ids[raw] orelse continue;
        if (id == expr_id) found_expr_storage = true;
        if (id == decl_id) found_decl_storage = true;
        if (id == outer_id) found_outer = true;
        if (id == param_id) found_param = true;
    }
    for (edited.references) |ref| {
        if (ref.node_index.isNone()) continue;
        const raw = @backingInt(ref.node_index);
        if (std.mem.indexOfScalar(u32, reachable, raw) == null) continue;
        if ((@backingInt(ref.symbol_id) == expr_id or @backingInt(ref.symbol_id) == decl_id) and
            raw >= transformer.parser_node_count and ref.flags.read) accessor_refs += 1;
    }
    try std.testing.expect(found_expr_storage and found_decl_storage and found_outer and found_param);
    try std.testing.expect(accessor_refs >= 2);

    const late_kind = @import("../semantic/symbol.zig").SyntheticKind.class_self_write_binding;
    var late_target_ids: [2]u32 = undefined;
    var late_target_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var late_target_count: usize = 0;
    var late_readonly_count: usize = 0;
    var late_ignored_parameter_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != late_kind) continue;
        try std.testing.expect(!symbol.scope_id.isNone());
        if (std.mem.eql(u8, symbol.synthetic_name, "_classSelfWrite")) {
            try std.testing.expect(late_target_count < late_target_ids.len);
            late_target_ids[late_target_count] = @intCast(raw_id);
            late_target_scopes[late_target_count] = symbol.scope_id;
            late_target_count += 1;
        } else if (std.mem.eql(u8, symbol.synthetic_name, "_classSelfReadonly")) {
            late_readonly_count += 1;
        } else if (std.mem.eql(u8, symbol.synthetic_name, "_ignoredClassSelfWrite")) {
            late_ignored_parameter_count += 1;
        } else {
            return error.UnexpectedClassSelfWriteSyntheticName;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), late_target_count);
    try std.testing.expectEqual(@as(usize, 2), late_readonly_count);
    try std.testing.expectEqual(@as(usize, 2), late_ignored_parameter_count);
    try std.testing.expect(late_target_ids[0] != late_target_ids[1]);
    try std.testing.expect(late_target_scopes[0] != late_target_scopes[1]);

    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != late_kind) continue;
        const symbol_id: u32 = @intCast(raw_id);
        try std.testing.expect(symbol.scope_id.toIndex() < edited.scope_maps.len);
        try std.testing.expectEqual(
            @as(?usize, symbol_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );
        var declaration_count: usize = 0;
        var exact_reference_count: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), symbol.synthetic_name)) continue;
            const exact_id = edited.symbol_ids[raw] orelse continue;
            if (exact_id != symbol_id) continue;
            if (node.tag == .binding_identifier) {
                declaration_count += 1;
            } else {
                exact_reference_count += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declaration_count);
        if (std.mem.eql(u8, symbol.synthetic_name, "_classSelfWrite") or
            std.mem.eql(u8, symbol.synthetic_name, "_classSelfReadonly"))
            try std.testing.expect(exact_reference_count > 0)
        else
            try std.testing.expectEqual(@as(usize, 0), exact_reference_count);
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != symbol_id or reference.node_index.isNone()) continue;
            const reference_raw = @backingInt(reference.node_index);
            try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[reference_raw]);
            var visible_scope = reference.scope_id;
            var is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (edited.scope_maps[visible_scope.toIndex()].get(symbol.synthetic_name)) |visible_id| {
                    if (visible_id == symbol_id) {
                        is_visible = true;
                        break;
                    }
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(is_visible);
        }
    }

    const alias_kind = @import("../semantic/symbol.zig").SyntheticKind.class_self_alias_binding;
    var alias_ids: [2]u32 = undefined;
    var alias_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var alias_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != alias_kind) continue;
        try std.testing.expectEqualStrings("_classSelf", symbol.synthetic_name);
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expect(alias_count < alias_ids.len);
        alias_ids[alias_count] = @intCast(raw_id);
        alias_scopes[alias_count] = symbol.scope_id;
        alias_count += 1;

        const symbol_id: u32 = @intCast(raw_id);
        try std.testing.expect(symbol.scope_id.toIndex() < edited.scope_maps.len);
        try std.testing.expectEqual(
            @as(?usize, symbol_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );
        var binding_count: usize = 0;
        var reference_count: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), symbol.synthetic_name)) continue;
            if (edited.symbol_ids[raw] != symbol_id) continue;
            if (node.tag == .binding_identifier) binding_count += 1 else reference_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        try std.testing.expect(reference_count > 0);
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != symbol_id or reference.node_index.isNone()) continue;
            const reference_raw = @backingInt(reference.node_index);
            try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[reference_raw]);
            var visible_scope = reference.scope_id;
            var is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (edited.scope_maps[visible_scope.toIndex()].get(symbol.synthetic_name)) |visible_id| {
                    if (visible_id == symbol_id) {
                        is_visible = true;
                        break;
                    }
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(is_visible);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), alias_count);
    try std.testing.expect(alias_ids[0] != alias_ids[1]);
    try std.testing.expect(alias_scopes[0] != alias_scopes[1]);
}

test "#4819 ES5 class IIFE scopes enclose source class bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Declared { value() { return 1; } }
        \\const Named = class Inner { value() { return 2; } };
        \\const Anonymous = class { value() { return 3; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var sources: std.ArrayList(struct { scope: u32, parent: @import("../semantic/scope.zig").ScopeId }) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult;
        try sources.append(allocator, .{ .scope = scope, .parent = analyzer.scopes.items[scope].parent });
    }
    try std.testing.expectEqual(@as(usize, 3), sources.items.len);
    var declared_inner: ?u32 = null;
    var declared_outer: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration) continue;
        const name_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").ClassExtra.name];
        declared_inner = analyzer.class_self_symbol_map.get(@intCast(raw));
        declared_outer = analyzer.symbol_ids.items[name_raw];
        break;
    }
    const inner_id = declared_inner orelse return error.TestUnexpectedResult;
    const outer_id = declared_outer orelse return error.TestUnexpectedResult;
    try std.testing.expect(inner_id != outer_id);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    for (sources.items) |item| {
        const wrapper = edited.scopes[item.scope].parent;
        try std.testing.expect(!wrapper.isNone());
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
        try std.testing.expectEqual(item.parent, edited.scopes[wrapper.toIndex()].parent);
        try std.testing.expect(edited.scopes[wrapper.toIndex()].is_strict);
        var owners: usize = 0;
        var it = edited.scope_owner_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(wrapper)) continue;
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, entry.key_ptr.*) != null);
            owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
    }
    const inner_scope = edited.symbols.items[inner_id].scope_id;
    try std.testing.expectEqual(edited.scopes[sources.items[0].scope].parent, inner_scope);
    try std.testing.expectEqual(@as(?usize, @intCast(inner_id)), edited.scope_maps[inner_scope.toIndex()].get("Declared"));
    try std.testing.expectEqual(@as(?usize, @intCast(outer_id)), edited.scope_maps[edited.symbols.items[outer_id].scope_id.toIndex()].get("Declared"));
    var inner_binding_live = false;
    var outer_binding_live = false;
    for (reachable) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == inner_id) inner_binding_live = true;
        if (edited.symbol_ids[raw] == outer_id) outer_binding_live = true;
    }
    try std.testing.expect(inner_binding_live and outer_binding_live);
}

test "#4819 ES5 named class expression stores exact inner self in wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const Value = class Named extends Object { static self() { return Named; } };");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_expression) continue;
        const candidate = analyzer.class_self_symbol_map.get(@intCast(raw)) orelse continue;
        source_scope = analyzer.scope_owner_map.get(@intCast(raw));
        inner_id = candidate;
        break;
    }
    const class_scope = source_scope orelse return error.TestUnexpectedResult;
    const inner = inner_id orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const wrapper = edited.scopes[class_scope].parent;
    try std.testing.expectEqual(wrapper, edited.symbols.items[inner].scope_id);
    try std.testing.expectEqual(@as(?usize, @intCast(inner)), edited.scope_maps[wrapper.toIndex()].get("Named"));
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live_binding = false;
    for (reachable) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == inner) live_binding = true;
    }
    try std.testing.expect(live_binding);
}

test "#4819 ES5 class IIFE check alias does not resolve to shadowing parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const X = class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } };");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) {
            source_scope = analyzer.scope_owner_map.get(@intCast(raw));
            inner_id = analyzer.class_self_symbol_map.get(@intCast(raw));
        } else if (node.tag == .method_definition and ctor_scope == null) {
            ctor_scope = analyzer.scope_owner_map.get(@intCast(raw));
        }
    }
    const class_scope = source_scope orelse return error.TestUnexpectedResult;
    const inner = inner_id orelse return error.TestUnexpectedResult;
    const constructor_scope = ctor_scope orelse return error.TestUnexpectedResult;
    const parameter = analyzer.scope_maps.items[constructor_scope].get("Inner") orelse return error.TestUnexpectedResult;
    try std.testing.expect(parameter != inner);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const wrapper = edited.scopes[class_scope].parent;
    try std.testing.expectEqual(wrapper, edited.symbols.items[inner].scope_id);
    const alias = edited.scope_maps[wrapper.toIndex()].get("_classSelf") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias != inner and alias != parameter);
    try std.testing.expectEqual(@as(?usize, @intCast(parameter)), edited.scope_maps[constructor_scope].get("Inner"));
    var alias_constructor_reads: usize = 0;
    var inner_wrapper_reads: usize = 0;
    for (edited.references) |ref| {
        if (!ref.flags.read or ref.node_index.isNone()) continue;
        if (@backingInt(ref.symbol_id) == alias and @backingInt(ref.scope_id) == constructor_scope)
            alias_constructor_reads += 1;
        if (@backingInt(ref.symbol_id) == inner and ref.scope_id == wrapper)
            inner_wrapper_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_constructor_reads);
    // The exact class-self ID is used by the wrapper's constructor binding,
    // IIFE call, and final return. None may resolve to the shadowing parameter.
    try std.testing.expectEqual(@as(usize, 3), inner_wrapper_reads);
}

test "#4819 ES5 class declaration IIFE check keeps outer and inner identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    var outer_id: ?u32 = null;
    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) {
            source_scope = analyzer.scope_owner_map.get(@intCast(raw));
            inner_id = analyzer.class_self_symbol_map.get(@intCast(raw));
            const name_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").ClassExtra.name];
            outer_id = analyzer.symbol_ids.items[name_raw];
        } else if (node.tag == .method_definition and ctor_scope == null) {
            ctor_scope = analyzer.scope_owner_map.get(@intCast(raw));
        }
    }
    const class_scope = source_scope orelse return error.TestUnexpectedResult;
    const inner = inner_id orelse return error.TestUnexpectedResult;
    const outer = outer_id orelse return error.TestUnexpectedResult;
    const constructor_scope = ctor_scope orelse return error.TestUnexpectedResult;
    const parameter = analyzer.scope_maps.items[constructor_scope].get("Inner") orelse return error.TestUnexpectedResult;
    try std.testing.expect(inner != outer and inner != parameter and outer != parameter);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const wrapper = edited.scopes[class_scope].parent;
    try std.testing.expectEqual(wrapper, edited.symbols.items[inner].scope_id);
    try std.testing.expect(edited.symbols.items[outer].scope_id != wrapper);
    const alias = edited.scope_maps[wrapper.toIndex()].get("_classSelf") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias != inner and alias != outer and alias != parameter);
    var alias_constructor_reads: usize = 0;
    var inner_wrapper_reads: usize = 0;
    for (edited.references) |ref| {
        if (!ref.flags.read or ref.node_index.isNone()) continue;
        if (@backingInt(ref.symbol_id) == alias and @backingInt(ref.scope_id) == constructor_scope)
            alias_constructor_reads += 1;
        if (@backingInt(ref.symbol_id) == inner and ref.scope_id == wrapper)
            inner_wrapper_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_constructor_reads);
    // The exact class-self ID is used by the wrapper's constructor binding,
    // IIFE call, and final return. None may resolve to the outer declaration
    // or the shadowing constructor parameter.
    try std.testing.expectEqual(@as(usize, 3), inner_wrapper_reads);
}

test "#4819 using class copies preserve exact source scope owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\using resource = { [Symbol.dispose]() {} };
        \\class Plain { value() { return 1; } }
        \\export class Named { value() { return 2; } }
        \\export default class Default { value() { return 3; } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scopes: std.ArrayList(u32) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration) continue;
        try source_scopes.append(allocator, analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult);
    }
    try std.testing.expectEqual(@as(usize, 3), source_scopes.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    for (source_scopes.items) |source_scope| {
        const wrapper = edited.scopes[source_scope].parent;
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
        var live_owners: usize = 0;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @backingInt(wrapper)) continue;
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, entry.key_ptr.*) != null);
            live_owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), live_owners);
    }
}

test "#4819 default derived constructors own exact newTarget symbols per function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base {}
        \\const _newTarget = 1;
        \\class First extends Base {}
        \\class Second extends Base {}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_symbols: std.ArrayList(struct { id: u32, scope: u32 }) = .empty;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_newTarget2")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const raw_id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        const scope_id = @backingInt(edited.symbols.items[raw_id].scope_id);
        try generated_symbols.append(allocator, .{ .id = raw_id, .scope = scope_id });
    }

    try std.testing.expectEqual(@as(usize, 2), generated_symbols.items.len);
    try std.testing.expect(generated_symbols.items[0].id != generated_symbols.items[1].id);
    try std.testing.expect(generated_symbols.items[0].scope != generated_symbols.items[1].scope);
    for (generated_symbols.items) |generated| {
        const scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(@intCast(generated.scope));
        try std.testing.expectEqual(@as(?usize, @intCast(generated.id)), edited.scope_maps[generated.scope].get("_newTarget2"));

        var declarations: usize = 0;
        var reads: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != generated.id) continue;
            if (reference.flags.declare) {
                declarations += 1;
                try std.testing.expectEqual(scope, reference.scope_id);
            }
            if (reference.flags.read) {
                reads += 1;
                try std.testing.expectEqual(scope, reference.scope_id);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expectEqual(@as(usize, 1), reads);
    }
}

test "#4819 explicit derived constructor super calls reuse the exact newTarget handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base {}
        \\const _newTarget = 1;
        \\class ArrowSuper extends Base { constructor(readParam = () => new.target) { const readTarget = () => new.target; const call = () => super(); call(); readTarget(); readParam(); } }
        \\class DirectSuper extends Base { constructor() { super(); } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_symbols: std.ArrayList(struct { id: u32, scope: u32 }) = .empty;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_newTarget2")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const raw_id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[raw_id].kind != .variable_var) continue;
        const scope_id = @backingInt(edited.symbols.items[raw_id].scope_id);
        try generated_symbols.append(allocator, .{ .id = raw_id, .scope = scope_id });
    }

    try std.testing.expectEqual(@as(usize, 2), generated_symbols.items.len);
    try std.testing.expect(generated_symbols.items[0].id != generated_symbols.items[1].id);
    try std.testing.expect(generated_symbols.items[0].scope != generated_symbols.items[1].scope);
    var direct_read = false;
    var nested_read = false;
    var total_reads: usize = 0;
    for (generated_symbols.items) |generated| {
        const scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(@intCast(generated.scope));
        try std.testing.expectEqual(@as(?usize, @intCast(generated.id)), edited.scope_maps[generated.scope].get("_newTarget2"));

        var declarations: usize = 0;
        var reads: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != generated.id) continue;
            if (reference.flags.declare) {
                declarations += 1;
                try std.testing.expectEqual(scope, reference.scope_id);
            }
            if (reference.flags.read) {
                reads += 1;
                if (reference.scope_id == scope) direct_read = true else nested_read = true;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expect(reads >= 1 and reads <= 3);
        total_reads += reads;
    }
    try std.testing.expect(direct_read and nested_read);
    try std.testing.expectEqual(@as(usize, 4), total_reads);
}

test "#4819 derived field insertion tracks the exact generated super assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function __callSuper(value) { return value; }
        \\class Base {}
        \\class Child extends Base {
        \\  field = 1;
        \\  constructor() {
        \\    let result;
        \\    result = __callSuper(0);
        \\    super();
        \\  }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const root = try transformer.transform();
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    try std.testing.expectEqual(@as(usize, 1), transformer.generated_super_call_assignments.count());
    var marked_assignment: ?u32 = null;
    var user_helper_assignment: ?u32 = null;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .assignment_expression) continue;
        const left = transformer.ast.getNode(node.data.binary.left);
        const right = transformer.ast.getNode(node.data.binary.right);
        if ((left.tag == .identifier_reference or left.tag == .assignment_target_identifier) and
            std.mem.eql(u8, transformer.ast.getText(left.data.string_ref), "result") and
            right.tag == .call_expression)
        {
            const callee: NodeIndex = @fromBackingInt(@intCast(transformer.ast.extra_data.items[right.data.extra]));
            if (transformer.ast.getNode(callee).tag == .identifier_reference and
                std.mem.eql(u8, transformer.ast.getText(transformer.ast.getNode(callee).data.string_ref), "__callSuper"))
            {
                user_helper_assignment = raw;
            }
        }
        if (transformer.generated_super_call_assignments.contains(raw)) {
            try std.testing.expect(marked_assignment == null);
            marked_assignment = raw;
        }
    }
    const marked_raw = marked_assignment orelse return error.MissingGeneratedSuperAssignment;
    const fake_raw = user_helper_assignment orelse return error.MissingUserHelperLookalike;
    try std.testing.expect(marked_raw != fake_raw);

    const edited = (try transformer.finishSemanticEdit()).?;
    const generated = transformer.ast.nodes.items[marked_raw];
    const generated_left = generated.data.binary.left;
    const generated_symbol = edited.symbol_ids[@backingInt(generated_left)] orelse
        return error.GeneratedSuperAssignmentLostSymbolId;
    const generated_scope = edited.symbols.items[generated_symbol].scope_id;
    var binding_found = false;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == generated_symbol) binding_found = true;
    }
    try std.testing.expect(binding_found);
    try std.testing.expect(!generated_scope.isNone());
    try std.testing.expect(!transformer.generated_super_call_assignments.contains(fake_raw));
    try std.testing.expectEqual(root, transformer.ast.transformed_root.?);
}

test "#4819 Stage 3 class copy nests under decorator and ES5 IIFE scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\@logged
        \\class Box { @logged method() { return 1; } constructor() { this.ready = true; } @logged value = 6; @logged other = 7; @logged accessor current = 8; @logged static staticValue = 9; @logged static method() { return 2; } @logged static get currentStatic() { return 3; } @logged #secret() { return 4; } @logged static #staticSecret() { return 5; } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    const source_parent = analyzer.scopes.items[source_scope].parent;

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const class_iife = edited.scopes[source_scope].parent;
    const decorator_iife = edited.scopes[class_iife.toIndex()].parent;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[class_iife.toIndex()].kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[decorator_iife.toIndex()].kind);
    try std.testing.expectEqual(source_parent, edited.scopes[decorator_iife.toIndex()].parent);

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var metadata_id: ?u32 = null;
    var metadata_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_metadata")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_const) continue;
        metadata_id = id;
        metadata_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), metadata_bindings);
    const exact_metadata_id = metadata_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_metadata_binding,
        edited.symbols.items[exact_metadata_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_metadata", edited.symbols.items[exact_metadata_id].synthetic_name);
    const metadata_scope = edited.symbols.items[exact_metadata_id].scope_id;
    try std.testing.expectEqual(class_iife, metadata_scope);
    try std.testing.expectEqual(@as(?usize, exact_metadata_id), edited.scope_maps[metadata_scope.toIndex()].get("_metadata"));

    var metadata_reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_metadata_id) continue;
        if (!reference.flags.read) continue;
        if (reference.node_index.isNone()) return error.TestUnexpectedResult;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_metadata", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        var visible_scope = reference.scope_id;
        var metadata_is_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == metadata_scope) {
                metadata_is_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(metadata_is_visible);
        metadata_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), metadata_reads);

    for ([_][]const u8{ "_value_initializers", "_other_initializers", "_current_initializers", "_staticValue_initializers" }) |initializer_name| {
        var initializer_id: ?u32 = null;
        var initializer_bindings: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), initializer_name)) continue;
            if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
            const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            if (edited.symbols.items[id].kind != .variable_let) continue;
            initializer_id = id;
            initializer_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), initializer_bindings);
        const exact_initializer_id = initializer_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[exact_initializer_id].synthetic_kind.?,
        );
        const initializer_scope = edited.symbols.items[exact_initializer_id].scope_id;
        try std.testing.expectEqual(decorator_iife, initializer_scope);
        try std.testing.expectEqual(
            @as(?usize, exact_initializer_id),
            edited.scope_maps[initializer_scope.toIndex()].get(initializer_name),
        );

        var initializer_reads: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != exact_initializer_id or reference.node_index.isNone()) continue;
            const node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings(initializer_name, transformer.ast.getText(node.data.string_ref));
            try std.testing.expect(reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            var visible_scope = reference.scope_id;
            var initializer_is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (visible_scope == initializer_scope) {
                    initializer_is_visible = true;
                    break;
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(initializer_is_visible);
            initializer_reads += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), initializer_reads);
    }

    const extra_initializer_cases = [_]struct { name: []const u8, reads: usize }{
        .{ .name = "_value_extraInitializers", .reads = 2 },
        .{ .name = "_other_extraInitializers", .reads = 2 },
        .{ .name = "_current_extraInitializers", .reads = 2 },
        // `__esDecorate` and the flush at the class end (#5712).
        .{ .name = "_staticValue_extraInitializers", .reads = 2 },
    };
    for (extra_initializer_cases) |case| {
        var extra_initializer_id: ?u32 = null;
        var extra_initializer_bindings: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), case.name)) continue;
            if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
            const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            if (edited.symbols.items[id].kind != .variable_let) continue;
            extra_initializer_id = id;
            extra_initializer_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), extra_initializer_bindings);
        const exact_extra_initializer_id = extra_initializer_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[exact_extra_initializer_id].synthetic_kind.?,
        );
        const extra_initializer_scope = edited.symbols.items[exact_extra_initializer_id].scope_id;
        try std.testing.expectEqual(decorator_iife, extra_initializer_scope);
        try std.testing.expectEqual(
            @as(?usize, exact_extra_initializer_id),
            edited.scope_maps[extra_initializer_scope.toIndex()].get(case.name),
        );

        var extra_initializer_reads: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != exact_extra_initializer_id or reference.node_index.isNone()) continue;
            const node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings(case.name, transformer.ast.getText(node.data.string_ref));
            try std.testing.expect(reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            var visible_scope = reference.scope_id;
            var extra_initializer_is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (visible_scope == extra_initializer_scope) {
                    extra_initializer_is_visible = true;
                    break;
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(extra_initializer_is_visible);
            extra_initializer_reads += 1;
        }
        try std.testing.expectEqual(case.reads, extra_initializer_reads);
    }

    var class_decorators_id: ?u32 = null;
    var class_decorators_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classDecorators")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_decorators_id = id;
        class_decorators_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_decorators_bindings);
    const exact_class_decorators_id = class_decorators_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_decorator_binding,
        edited.symbols.items[exact_class_decorators_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classDecorators", edited.symbols.items[exact_class_decorators_id].synthetic_name);
    const class_decorators_scope = edited.symbols.items[exact_class_decorators_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_decorators_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_decorators_id),
        edited.scope_maps[class_decorators_scope.toIndex()].get("_classDecorators"),
    );

    var class_decorators_reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_class_decorators_id or !reference.flags.read) continue;
        if (reference.node_index.isNone()) return error.TestUnexpectedResult;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classDecorators", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_decorators_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_decorators_scope) {
                class_decorators_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_decorators_are_visible);
        class_decorators_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_decorators_reads);

    var class_descriptor_id: ?u32 = null;
    var class_descriptor_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classDescriptor")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_descriptor_id = id;
        class_descriptor_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_descriptor_bindings);
    const exact_class_descriptor_id = class_descriptor_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_decorator_binding,
        edited.symbols.items[exact_class_descriptor_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classDescriptor", edited.symbols.items[exact_class_descriptor_id].synthetic_name);
    const class_descriptor_scope = edited.symbols.items[exact_class_descriptor_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_descriptor_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_descriptor_id),
        edited.scope_maps[class_descriptor_scope.toIndex()].get("_classDescriptor"),
    );

    var class_descriptor_reads: usize = 0;
    var class_descriptor_writes: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_class_descriptor_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(!reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            continue;
        }
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classDescriptor", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_descriptor_is_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_descriptor_scope) {
                class_descriptor_is_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_descriptor_is_visible);
        if (reference.flags.write) {
            try std.testing.expect(!reference.flags.read);
            class_descriptor_writes += 1;
        } else {
            try std.testing.expect(reference.flags.read);
            class_descriptor_reads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), class_descriptor_reads);
    try std.testing.expectEqual(@as(usize, 1), class_descriptor_writes);

    var class_extra_initializers_id: ?u32 = null;
    var class_extra_initializers_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_extra_initializers_id = id;
        class_extra_initializers_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_extra_initializers_bindings);
    const exact_class_extra_initializers_id = class_extra_initializers_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_decorator_binding,
        edited.symbols.items[exact_class_extra_initializers_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classExtraInitializers", edited.symbols.items[exact_class_extra_initializers_id].synthetic_name);
    const class_extra_initializers_scope = edited.symbols.items[exact_class_extra_initializers_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_extra_initializers_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_extra_initializers_id),
        edited.scope_maps[class_extra_initializers_scope.toIndex()].get("_classExtraInitializers"),
    );

    var class_extra_initializers_reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_class_extra_initializers_id or !reference.flags.read) continue;
        if (reference.node_index.isNone()) return error.TestUnexpectedResult;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classExtraInitializers", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_extra_initializers_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_extra_initializers_scope) {
                class_extra_initializers_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_extra_initializers_are_visible);
        class_extra_initializers_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), class_extra_initializers_reads);

    var class_this_id: ?u32 = null;
    var class_this_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classThis")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_this_id = id;
        class_this_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_this_bindings);
    const exact_class_this_id = class_this_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_this_binding,
        edited.symbols.items[exact_class_this_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classThis", edited.symbols.items[exact_class_this_id].synthetic_name);
    const class_this_scope = edited.symbols.items[exact_class_this_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_this_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_this_id),
        edited.scope_maps[class_this_scope.toIndex()].get("_classThis"),
    );

    var class_this_reads: usize = 0;
    var class_this_writes: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_class_this_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(!reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            continue;
        }
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classThis", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_this_is_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_this_scope) {
                class_this_is_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_this_is_visible);
        if (reference.flags.write) {
            try std.testing.expect(!reference.flags.read);
            class_this_writes += 1;
        } else {
            try std.testing.expect(reference.flags.read);
            class_this_reads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), class_this_reads);
    try std.testing.expectEqual(@as(usize, 2), class_this_writes);

    var static_extra_initializers_id: ?u32 = null;
    var static_extra_initializers_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_staticExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        static_extra_initializers_id = id;
        static_extra_initializers_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), static_extra_initializers_bindings);
    const exact_static_extra_initializers_id = static_extra_initializers_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
        edited.symbols.items[exact_static_extra_initializers_id].synthetic_kind.?,
    );
    const static_extra_initializers_scope = edited.symbols.items[exact_static_extra_initializers_id].scope_id;
    try std.testing.expectEqual(decorator_iife, static_extra_initializers_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_static_extra_initializers_id),
        edited.scope_maps[static_extra_initializers_scope.toIndex()].get("_staticExtraInitializers"),
    );

    var static_extra_initializers_reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_static_extra_initializers_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(!reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            continue;
        }
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_staticExtraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var static_extra_initializers_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == static_extra_initializers_scope) {
                static_extra_initializers_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(static_extra_initializers_are_visible);
        static_extra_initializers_reads += 1;
    }
    // Three static method `__esDecorate` calls, and the first static field
    // runs them (#5712).
    try std.testing.expectEqual(@as(usize, 4), static_extra_initializers_reads);

    var instance_extra_initializers_id: ?u32 = null;
    var instance_extra_initializers_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_instanceExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        instance_extra_initializers_id = id;
        instance_extra_initializers_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), instance_extra_initializers_bindings);
    const exact_instance_extra_initializers_id = instance_extra_initializers_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
        edited.symbols.items[exact_instance_extra_initializers_id].synthetic_kind.?,
    );
    const instance_extra_initializers_scope = edited.symbols.items[exact_instance_extra_initializers_id].scope_id;
    try std.testing.expectEqual(decorator_iife, instance_extra_initializers_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_instance_extra_initializers_id),
        edited.scope_maps[instance_extra_initializers_scope.toIndex()].get("_instanceExtraInitializers"),
    );

    var instance_extra_initializers_reads: usize = 0;
    var instance_extra_initializers_reference_scopes: [3]@import("../semantic/scope.zig").ScopeId = undefined;
    var instance_extra_initializers_scope_counts: [3]usize = .{ 0, 0, 0 };
    var instance_extra_initializers_scope_len: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_instance_extra_initializers_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_instanceExtraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var instance_extra_initializers_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == instance_extra_initializers_scope) {
                instance_extra_initializers_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(instance_extra_initializers_are_visible);
        var scope_slot: usize = 0;
        while (scope_slot < instance_extra_initializers_scope_len) : (scope_slot += 1) {
            if (instance_extra_initializers_reference_scopes[scope_slot] == reference.scope_id) break;
        }
        if (scope_slot == instance_extra_initializers_scope_len) {
            if (instance_extra_initializers_scope_len == instance_extra_initializers_reference_scopes.len) return error.TestUnexpectedResult;
            instance_extra_initializers_reference_scopes[scope_slot] = reference.scope_id;
            instance_extra_initializers_scope_len += 1;
        }
        instance_extra_initializers_scope_counts[scope_slot] += 1;
        instance_extra_initializers_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), instance_extra_initializers_reads);
    try std.testing.expectEqual(@as(usize, 2), instance_extra_initializers_scope_len);
    try std.testing.expect(
        (instance_extra_initializers_scope_counts[0] == 2 and instance_extra_initializers_scope_counts[1] == 1) or
            (instance_extra_initializers_scope_counts[0] == 1 and instance_extra_initializers_scope_counts[1] == 2),
    );

    var member_decorator_bindings: usize = 0;
    var member_decorator_names: std.ArrayList([]const u8) = .empty;
    defer member_decorator_names.deinit(allocator);
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (std.mem.indexOf(u8, name, "_decorators") == null) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[id].synthetic_kind.?,
        );
        member_decorator_bindings += 1;
        const decorator_scope = edited.symbols.items[id].scope_id;
        try std.testing.expectEqual(decorator_iife, decorator_scope);
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[decorator_scope.toIndex()].get(name));
        for (member_decorator_names.items) |previous| try std.testing.expect(!std.mem.eql(u8, previous, name));
        try member_decorator_names.append(allocator, name);

        var reads: usize = 0;
        var writes: usize = 0;
        var reference_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id or reference.node_index.isNone()) continue;
            const reference_node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, reference_node.tag);
            try std.testing.expectEqualStrings(name, transformer.ast.getText(reference_node.data.string_ref));
            if (reference_scope) |previous_scope| {
                try std.testing.expectEqual(previous_scope, reference.scope_id);
            } else {
                reference_scope = reference.scope_id;
            }
            if (reference.flags.write) {
                try std.testing.expect(!reference.flags.read);
                writes += 1;
            } else {
                try std.testing.expect(reference.flags.read);
                reads += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), reads);
        try std.testing.expectEqual(@as(usize, 1), writes);
        try std.testing.expect(reference_scope != null);
    }
    try std.testing.expectEqual(@as(usize, 9), member_decorator_bindings);

    for ([_][]const u8{ "_private_secret_descriptor", "_private_staticSecret_descriptor" }) |descriptor_name| {
        var private_descriptor_id: ?u32 = null;
        var private_descriptor_bindings: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), descriptor_name)) continue;
            if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
            const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            if (edited.symbols.items[id].kind != .variable_let) continue;
            private_descriptor_id = id;
            private_descriptor_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), private_descriptor_bindings);
        const exact_private_descriptor_id = private_descriptor_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[exact_private_descriptor_id].synthetic_kind.?,
        );
        const private_descriptor_scope = edited.symbols.items[exact_private_descriptor_id].scope_id;
        try std.testing.expectEqual(decorator_iife, private_descriptor_scope);
        try std.testing.expectEqual(
            @as(?usize, exact_private_descriptor_id),
            edited.scope_maps[private_descriptor_scope.toIndex()].get(descriptor_name),
        );

        var private_descriptor_reads: usize = 0;
        var private_descriptor_writes: usize = 0;
        var private_descriptor_read_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        var private_descriptor_write_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != exact_private_descriptor_id or reference.node_index.isNone()) continue;
            const node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings(descriptor_name, transformer.ast.getText(node.data.string_ref));
            var visible_scope = reference.scope_id;
            var descriptor_is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (visible_scope == private_descriptor_scope) {
                    descriptor_is_visible = true;
                    break;
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(descriptor_is_visible);
            if (reference.flags.write) {
                try std.testing.expect(!reference.flags.read);
                private_descriptor_writes += 1;
                private_descriptor_write_scope = reference.scope_id;
            } else {
                try std.testing.expect(reference.flags.read);
                private_descriptor_reads += 1;
                try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[reference.scope_id.toIndex()].kind);
                private_descriptor_read_scope = reference.scope_id;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), private_descriptor_reads);
        try std.testing.expectEqual(@as(usize, 1), private_descriptor_writes);
        try std.testing.expect(private_descriptor_read_scope.? != private_descriptor_write_scope.?);
    }
}

test "#4819 Stage 3 member extra initializer binds its synthetic constructor read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box { @logged value = 6; }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var extra_initializer_id: ?u32 = null;
    var bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_value_extraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        extra_initializer_id = id;
        bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    const exact_id = extra_initializer_id orelse return error.TestUnexpectedResult;
    const binding_scope = edited.symbols.items[exact_id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[binding_scope.toIndex()].kind);
    try std.testing.expect(binding_scope.toIndex() != source_scope);
    try std.testing.expectEqual(@as(?usize, exact_id), edited.scope_maps[binding_scope.toIndex()].get("_value_extraInitializers"));

    var reads: usize = 0;
    var read_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_value_extraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == binding_scope) {
                visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(visible);
        if (reads >= read_scopes.len) return error.TestUnexpectedResult;
        read_scopes[reads] = reference.scope_id;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expect(read_scopes[0] != read_scopes[1]);
}

test "#4819 Stage 3 instance extra initializer keeps exact block and constructor reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box { @logged method() { return 1; } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var instance_initializer_id: ?u32 = null;
    var bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_instanceExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        instance_initializer_id = id;
        bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    const exact_id = instance_initializer_id orelse return error.TestUnexpectedResult;
    const binding_scope = edited.symbols.items[exact_id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[binding_scope.toIndex()].kind);
    try std.testing.expect(binding_scope.toIndex() != source_scope);
    try std.testing.expectEqual(@as(?usize, exact_id), edited.scope_maps[binding_scope.toIndex()].get("_instanceExtraInitializers"));

    var reads: usize = 0;
    var read_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_instanceExtraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[reference.scope_id.toIndex()].kind);
        var visible_scope = reference.scope_id;
        var visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == binding_scope) {
                visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(visible);
        if (reads >= read_scopes.len) return error.TestUnexpectedResult;
        read_scopes[reads] = reference.scope_id;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expect(read_scopes[0] != read_scopes[1]);
}

test "#4819 ES5 class methods retain original scope on emitted functions and bind body temps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Box {
        \\  stamp = 0;
        \\  constructor(v) { this.value = v.next() ?? 1; }
        \\  ["read"](x) { return x.next() ?? this.value; }
        \\  get current() { return this.read() ?? 0; }
        \\  set current(v) { this.value = v.next() ?? 2; }
        \\}
        \\const Direct = class Named { constructor(v) { this.value = v.next() ?? 3; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var original_methods: std.ArrayList(struct { owner: NodeIndex, scope: u32 }) = .empty;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const owner: NodeIndex = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
        if (analyzer.scope_owner_map.get(@backingInt(owner))) |scope| {
            try original_methods.append(allocator, .{ .owner = owner, .scope = scope });
        }
    }
    try std.testing.expectEqual(@as(usize, 5), original_methods.items.len);

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_temp_refs: usize = 0;
    for (original_methods.items) |method| {
        try std.testing.expect(edited.scope_owner_map.get(@backingInt(method.owner)) == null);
        var final_owner: ?NodeIndex = null;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != method.scope) continue;
            try std.testing.expect(final_owner == null);
            final_owner = @fromBackingInt(@intCast(entry.key_ptr.*));
        }
        const owner = final_owner orelse return error.TestUnexpectedResult;
        const tag = transformer.ast.getNode(owner).tag;
        try std.testing.expect(tag == .function_declaration or tag == .function_expression);
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @backingInt(owner)) != null);
    }
    for (edited.references) |ref| {
        if (ref.node_index.isNone() or @backingInt(ref.node_index) < transformer.parser_node_count) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.startsWith(u8, name, "_")) continue;
        for (original_methods.items) |method| {
            if (@backingInt(ref.scope_id) == method.scope) generated_temp_refs += 1;
        }
    }
    try std.testing.expect(generated_temp_refs >= 5);
}

test "#4819 simple named class keeps inner name environment and binds constructor check alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const X = class C { constructor(C) { this.value = C; } };");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    var constructor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) {
            class_scope = analyzer.scope_owner_map.get(@intCast(raw));
            inner_id = analyzer.class_self_symbol_map.get(@intCast(raw));
        } else if (node.tag == .method_definition) {
            constructor_scope = analyzer.scope_owner_map.get(@intCast(raw));
        }
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    const self_id = inner_id orelse return error.TestUnexpectedResult;
    const ctor_scope = constructor_scope orelse return error.TestUnexpectedResult;
    const original_parent = analyzer.scopes.items[source_scope].parent;

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const wrapper = edited.scopes[source_scope].parent;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
    try std.testing.expectEqual(original_parent, edited.scopes[wrapper.toIndex()].parent);
    try std.testing.expectEqual(@as(@import("../semantic/scope.zig").ScopeId, @fromBackingInt(@intCast(source_scope))), edited.symbols.items[self_id].scope_id);
    const alias = edited.scope_maps[wrapper.toIndex()].get("_classSelf") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias != self_id);
    var wrapper_reads: usize = 0;
    var ctor_reads: usize = 0;
    for (edited.references) |ref| {
        if (@backingInt(ref.symbol_id) != alias or !ref.flags.read) continue;
        if (ref.scope_id == wrapper) wrapper_reads += 1;
        if (@backingInt(ref.scope_id) == ctor_scope) ctor_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wrapper_reads);
    try std.testing.expectEqual(@as(usize, 1), ctor_reads);
}

test "#4819 anonymous ES5 class expression name gets an exact SymbolId before wrapper refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const _Class = 17; function consume(value) {} consume(class { method() { return 1; } });";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_name_id: ?u32 = null;
    var generated_name_bindings: usize = 0;
    var generated_name: ?[]const u8 = null;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse continue;
        if (edited.symbols.items[id].kind != .function_decl) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.startsWith(u8, name, "_Class")) continue;
        generated_name_id = id;
        generated_name = name;
        generated_name_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), generated_name_bindings);
    const exact_id = generated_name_id orelse return error.TestUnexpectedResult;
    const exact_name = generated_name orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, exact_name, "_Class"));
    const binding_scope = edited.symbols.items[exact_id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[binding_scope.toIndex()].kind);
    try std.testing.expectEqual(@as(?usize, exact_id), edited.scope_maps[binding_scope.toIndex()].get(exact_name));
    try std.testing.expectEqual(binding_scope, edited.scopes[source_scope].parent);

    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != exact_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings(exact_name, transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == binding_scope) {
                visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(visible);
        reads += 1;
    }
    // The fourth read restores the anonymous class's empty `.name` (#5519).
    try std.testing.expectEqual(@as(usize, 4), reads);
}

test "#4819 anonymous ES5 class expression names are finalized from exact SymbolIds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "var First = class { method() { return 1; } }; var Second = class { method() { return 2; } };";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var late_class_self_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var late_class_self_count: usize = 0;
    for (edited.symbols.items) |symbol| {
        if (symbol.synthetic_kind != .anonymous_class_expression_binding) continue;
        try std.testing.expectEqualStrings("_Class", symbol.synthetic_name);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.function_decl, symbol.kind);
        if (late_class_self_count >= late_class_self_scopes.len) return error.TestUnexpectedResult;
        late_class_self_scopes[late_class_self_count] = symbol.scope_id;
        late_class_self_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), late_class_self_count);
    try std.testing.expect(late_class_self_scopes[0] != late_class_self_scopes[1]);
}

test "#4819 anonymous ES5 class expression name reserves identifiers seen by direct eval" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "var Holder = class { static read() { return eval('typeof _Class'); } };";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

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
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var found_binding = false;
    for (edited.symbols.items) |symbol| {
        if (symbol.kind != .function_decl or !std.mem.startsWith(u8, symbol.synthetic_name, "_Class")) continue;
        try std.testing.expectEqualStrings("_Class2", symbol.synthetic_name);
        try std.testing.expect(symbol.synthetic_kind != .anonymous_class_expression_binding);
        found_binding = true;
    }
    try std.testing.expect(found_binding);
}

test "#4819 anonymous default ES5 class export has an exact generated binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "class Base { static read() { return 1; } } const _Class = 17; const _Class2 = 18; export default class extends Base { static self() { return super.read(); } }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
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
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("anonymous-default-class-es5.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var generated_bindings: usize = 0;
    var outer_symbol: ?u32 = null;
    var inner_symbol: ?u32 = null;
    for (reachable) |raw| {
        const binding = transformer.ast.nodes.items[raw];
        if (binding.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(binding.data.string_ref), "_Class3")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        generated_bindings += 1;
        switch (edited.symbols.items[id].kind) {
            .variable_var => outer_symbol = id,
            .function_decl => inner_symbol = id,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), generated_bindings);
    const outer_id = outer_symbol orelse return error.TestUnexpectedResult;
    const inner_id = inner_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expect(outer_id != inner_id);
    try std.testing.expectEqual(
        @as(?usize, outer_id),
        edited.scope_maps[edited.symbols.items[outer_id].scope_id.toIndex()].get("_Class3"),
    );
    try std.testing.expectEqual(
        @as(?usize, inner_id),
        edited.scope_maps[edited.symbols.items[inner_id].scope_id.toIndex()].get("_Class3"),
    );

    var export_uses_outer_symbol = false;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .export_default_declaration) continue;
        const operand: NodeIndex = node.data.unary.operand;
        if (operand.isNone() or @backingInt(operand) >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[@backingInt(operand)] == outer_id) export_uses_outer_symbol = true;
    }
    try std.testing.expect(export_uses_outer_symbol);

    var inner_reads: usize = 0;
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) == inner_id and reference.flags.read) inner_reads += 1;
    }
    try std.testing.expect(inner_reads > 0);
}

test "#4819 anonymous default ES5 class export marks its late output name by SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export default class { static value() { return 1; } }");
    var parser = Parser.init(allocator, &scanner);
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var outer_class_symbols: usize = 0;
    for (edited.symbols.items) |symbol| {
        if ((symbol.synthetic_kind orelse continue) != .anonymous_class_export_binding) continue;
        try std.testing.expectEqualStrings("_Class", symbol.synthetic_name);
        outer_class_symbols += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), outer_class_symbols);
}

test "#4819 Stage 3 decorated anonymous default class preserves exact generated names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function tag(value, context) { return value; }
        \\@tag
        \\export default class { static value = 1; }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
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
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var wrapper_symbol: ?usize = null;
    var constructor_symbol: ?usize = null;
    for (edited.symbols.items, 0..) |symbol, id| {
        if (!std.mem.eql(u8, symbol.synthetic_name, "_Class")) continue;
        if (symbol.kind == .variable_var and symbol.synthetic_kind == .anonymous_class_export_binding) wrapper_symbol = id;
        if (symbol.kind == .function_decl and symbol.synthetic_kind == .anonymous_class_expression_binding) constructor_symbol = id;
    }
    const wrapper_id = wrapper_symbol orelse return error.TestUnexpectedResult;
    const constructor_id = constructor_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expect(wrapper_id != constructor_id);
    try std.testing.expect(edited.symbols.items[wrapper_id].scope_id != edited.symbols.items[constructor_id].scope_id);
    try std.testing.expectEqualStrings(
        "_Class",
        transformer.late_output_name_bases.get("_Class") orelse return error.MissingStage3AnonymousClassOutputNameBase,
    );

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    var wrapper_binding_count: usize = 0;
    var wrapper_write_count: usize = 0;
    var wrapper_owner_scope_writes: usize = 0;
    var wrapper_metadata_scope_writes: usize = 0;
    var constructor_binding_count: usize = 0;
    var wrapper_reference_node_count: usize = 0;
    for (reachable) |reachable_node| {
        const raw = reachable_node;
        const node = transformer.ast.getNode(@fromBackingInt(@intCast(raw)));
        const name_span = switch (node.tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier => node.data.string_ref,
            else => continue,
        };
        if (!std.mem.eql(u8, transformer.ast.getText(name_span), "_Class")) continue;
        const symbol_id = if (raw < edited.symbol_ids.len) edited.symbol_ids[raw] else null;
        const exact_id = symbol_id orelse continue;
        if (exact_id == wrapper_id and node.tag == .binding_identifier) wrapper_binding_count += 1;
        if (exact_id == constructor_id and node.tag == .binding_identifier) constructor_binding_count += 1;
        if (exact_id == wrapper_id and (node.tag == .identifier_reference or node.tag == .assignment_target_identifier)) {
            wrapper_reference_node_count += 1;
            var found_reference = false;
            for (edited.references) |reference| {
                if (reference.node_index != @as(NodeIndex, @fromBackingInt(@intCast(raw)))) continue;
                found_reference = true;
            }
            try std.testing.expect(found_reference);
        }
    }
    for (edited.references) |reference| {
        if (@backingInt(reference.symbol_id) != wrapper_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        try std.testing.expect(reference.flags.write);
        try std.testing.expect(!reference.flags.read);
        if (reference.scope_id == edited.symbols.items[wrapper_id].scope_id) {
            wrapper_owner_scope_writes += 1;
        } else {
            if (reference.scope_id.isNone() or reference.scope_id.toIndex() >= edited.scopes.len)
                return error.Stage3ClassWriteHasInvalidScope;
            const reference_scope = edited.scopes[reference.scope_id.toIndex()];
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, reference_scope.kind);
            try std.testing.expectEqual(edited.symbols.items[wrapper_id].scope_id, reference_scope.parent);
            var owner_found = false;
            var owner_it = edited.scope_owner_map.iterator();
            while (owner_it.next()) |entry| {
                if (entry.value_ptr.* != reference.scope_id.toIndex()) continue;
                const owner_node: NodeIndex = @fromBackingInt(entry.key_ptr.*);
                const owner = transformer.ast.getNode(owner_node);
                try std.testing.expectEqual(.function_expression, owner.tag);
                owner_found = true;
                break;
            }
            try std.testing.expect(owner_found);
            wrapper_metadata_scope_writes += 1;
        }
        wrapper_write_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wrapper_binding_count);
    try std.testing.expectEqual(@as(usize, 1), constructor_binding_count);
    try std.testing.expectEqual(@as(usize, 2), wrapper_reference_node_count);
    try std.testing.expectEqual(@as(usize, 2), wrapper_write_count);
    try std.testing.expectEqual(@as(usize, 1), wrapper_owner_scope_writes);
    try std.testing.expectEqual(@as(usize, 1), wrapper_metadata_scope_writes);
    var report = try coverage.checkStrictWithExactExternalEvidence(
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
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("stage3-anonymous-default-class-es5.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "#4819 inferred anonymous class does not gain a named-class wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const Inferred = class {}; console.log(Inferred.name);");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.class_self_symbol_map.count());

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.preserved_simple_class_names.items.len);
    _ = try transformer.finishSemanticEdit();
}

test "#4819 decorated explicit constructor binds generated nullish temp in original scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box {
        \\  @logged field = 1;
        \\  constructor(value) { this.field = value.next() ?? 2; }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const key_idx: NodeIndex = @fromBackingInt(@intCast(parser.ast.extra_data.items[node.data.extra + MethodExtra.key]));
        const key = parser.ast.getNode(key_idx);
        if (key.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(key.data.string_ref), "constructor")) continue;
        ctor_scope = analyzer.scope_owner_map.get(@as(u32, @intCast(index)));
    }
    const source_scope = ctor_scope orelse return error.TestUnexpectedResult;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;

    var ctor_owners: usize = 0;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != source_scope) continue;
        const owner: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        try std.testing.expect(transformer.ast.getNode(owner).tag == .function_declaration);
        ctor_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ctor_owners);

    var ctor_temp_refs: usize = 0;
    for (edited.references) |ref| {
        if (@backingInt(ref.scope_id) != source_scope or ref.node_index.isNone()) continue;
        if (@backingInt(ref.node_index) < transformer.parser_node_count) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.eql(u8, name, "_a")) continue;
        try std.testing.expectEqual(source_scope, @backingInt(edited.symbols.items[@backingInt(ref.symbol_id)].scope_id));
        ctor_temp_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ctor_temp_refs);
}

test "#4819 generated class super parameter owns colliding alias references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base { static get value() { return 3; } }
        \\const _super = 1;
        \\class Declared extends Base { constructor() { super(); } method() { return super.value; } static read() { return super.value; } }
        \\const Expression = class extends Base { method() { return super.value; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var super_parameter_ids: [2]u32 = undefined;
    var super_parameter_count: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_super2")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse continue;
        if (edited.symbols.items[id].kind != .parameter) continue;
        if (super_parameter_count >= super_parameter_ids.len) return error.TestUnexpectedResult;
        super_parameter_ids[super_parameter_count] = id;
        super_parameter_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), super_parameter_count);
    try std.testing.expect(super_parameter_ids[0] != super_parameter_ids[1]);

    var aliased_references: usize = 0;
    var parameter_reads = [_]usize{ 0, 0 };
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_super2")) continue;
        aliased_references += 1;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        var matched = false;
        for (super_parameter_ids, 0..) |parameter_id, index| {
            if (id != parameter_id) continue;
            parameter_reads[index] += 1;
            matched = true;
        }
        try std.testing.expect(matched);
        var semantic_reference_count: usize = 0;
        for (edited.references) |reference| {
            if (reference.node_index != @as(NodeIndex, @fromBackingInt(@intCast(raw)))) continue;
            try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
            try std.testing.expect(reference.flags.read);
            semantic_reference_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), semantic_reference_count);
    }
    try std.testing.expect(aliased_references > 0);
    try std.testing.expect(parameter_reads[0] > 0 and parameter_reads[1] > 0);
}

fn expectGeneratedNameEnvironment(source: []const u8, expected_names: usize, expected_strict: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    const source_root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    try analyzer.analyze();
    const source_scope_count = analyzer.scopes.items.len;
    var expected_parent: ScopeId = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_expression) continue;
        const class_scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult;
        expected_parent = analyzer.scopes.items[class_scope].parent;
    }
    try std.testing.expect(!expected_parent.isNone());
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const root = try t.visitNode(source_root);
    // No output walker or finish: these are creator-time graph facts.
    const editor = &t.semantic_editor.?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(a, t.ast, root);
    var found: usize = 0;
    for (reachable) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .function_expression) continue;
        const name = t.ast.readExtraNode(node.data.extra, 0);
        if (name.isNone()) continue;
        const id = t.getSymbolIdAt(name) orelse continue;
        const name_scope = editor.symbols.items[id].scope_id;
        if (name_scope.toIndex() < source_scope_count or editor.scopes.items[name_scope.toIndex()].kind != .block) continue;
        const outer = editor.scopes.items[name_scope.toIndex()].parent;
        try std.testing.expectEqual(expected_parent, outer);
        try std.testing.expectEqual(expected_strict, editor.scopes.items[outer.toIndex()].is_strict);
        try std.testing.expectEqual(editor.scopes.items[outer.toIndex()].is_strict, editor.scopes.items[name_scope.toIndex()].is_strict);
        const function_scope = t.outputOwnedScope(@fromBackingInt(raw)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(name_scope, editor.scopes.items[function_scope.toIndex()].parent);
        try std.testing.expect(editor.scopes.items[function_scope.toIndex()].is_strict);
        const body = t.ast.getNode(t.ast.readExtraNode(node.data.extra, 2));
        try std.testing.expect(body.data.list.len > 0);
        const first = t.ast.getNode(@fromBackingInt(@intCast(t.ast.extra_data.items[body.data.list.start])));
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.directive, first.tag);
        try std.testing.expect(std.mem.indexOf(u8, t.ast.getText(first.span), "use strict") != null);
        var reads: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) != id or !reference.flags.read) continue;
            try std.testing.expectEqual(function_scope, reference.scope_id);
            try std.testing.expectEqual(id, t.getSymbolIdAt(reference.node_index).?);
            reads += 1;
        }
        try std.testing.expect(reads > 0);
        found += 1;
    }
    try std.testing.expectEqual(expected_names, found);
    const report = try coverage.checkExact(a, t.ast, root, t.parser_node_count, editor.symbol_ids.items, editor.symbols.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, t.helper_ref_nodes.items, &t.helper_scope_map, &analyzer.unresolved_reference_nodes, &t.explicit_global_reference_nodes, &t.reference_origin_map);
    try std.testing.expectEqual(@as(usize, 0), report.scope_strictness_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.identity_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.reference_scope_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.duplicate_reference);
}

test "generated name environment inherits actual parent before output walker" {
    try expectGeneratedNameEnvironment("(()=>class{})();", 1, false);
    try expectGeneratedNameEnvironment("'use strict';(()=>class{})();", 1, true);
    try expectGeneratedNameEnvironment("function outer(){return class{}}outer();", 1, false);
    try expectGeneratedNameEnvironment("function outer(){'use strict';return class{}}outer();", 1, true);
    try expectGeneratedNameEnvironment("consume(class{});", 1, false);
    try expectGeneratedNameEnvironment("(()=>class Named{})();", 0, false);
    try expectGeneratedNameEnvironment("'use strict';(()=>class Named{})();", 0, true);
    try expectGeneratedNameEnvironment("function caseD(){(()=>({x:1}))();(()=>function(){})();(()=>class{})();}caseD();", 1, false);
    std.debug.print("GENERATED NAME ENV BIRTH controls=8 creator-only=1\n", .{});
}

test "generated name environment preserves native strict reflection and sloppy outer runtime" {
    const prelude = "function observe(fn){try{return ['return',fn()]}catch(e){return ['throw',e.name]}};";
    const sources = [_][]const u8{
        prelude ++ "var C=(()=>class{})();console.log(JSON.stringify(observe(()=>C.caller)));",
        prelude ++ "var C=(()=>class{})();console.log(JSON.stringify(observe(()=>C.arguments)));",
        prelude ++ "var C=(()=>class{})();console.log(JSON.stringify(observe(()=>C())));",
        prelude ++ "var C=(()=>class{})();console.log(JSON.stringify(observe(()=>C.call(undefined))));",
        "var C=(()=>class{})();var x=new C();console.log(JSON.stringify([x instanceof C,Object.getPrototypeOf(x)===C.prototype]));",
        "var C=(()=>class{constructor(){this.seen=(function(){return this===undefined})()}})();console.log(JSON.stringify(new C().seen));",
        prelude ++ "var C=(()=>class{constructor(){this.seen=observe(()=>arguments.callee)}})();console.log(JSON.stringify(new C().seen));",
        prelude ++ "var C=(()=>class Named{})();console.log(JSON.stringify(observe(()=>C.prototype.constructor.caller)));",
        "function outside(){return this===globalThis};var C=(()=>class{})();console.log(JSON.stringify([outside(),new C() instanceof C]));",
        "'use strict';function outside(){return this===undefined};var C=(()=>class{})();console.log(JSON.stringify([outside(),new C() instanceof C]));",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (sources) |source| {
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(a, source, "input.unknown", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5), .minify_identifiers = minify });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
    std.debug.print("GENERATED NAME ENV RUNTIME sources=10 modes=2 native=20\n", .{});
}

// Actual Parser/analyzer/creator pipeline. Post-transform rows are after the
// transformer's output binder; PRIVATE_BIRTH is a separate temporary probe.
fn privateSourceRedTuple(source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scanner = try a.create(Scanner);
    scanner.* = try Scanner.init(a, source);
    const parser = try a.create(Parser);
    parser.* = Parser.init(a, scanner);
    _ = try parser.parse();
    const analyzer = try a.create(SemanticAnalyzer);
    analyzer.* = SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .method_definition) continue;
        const actual_scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult;
        std.debug.print("PRIVATE_INITIAL_METHOD node={d} scope={d} span={d}:{d}\n", .{ raw, actual_scope, node.span.start, node.span.end });
    }
    const transformer = try a.create(Transformer);
    transformer.* = try Transformer.init(a, &parser.ast, .{
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
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(a, transformer.ast, root);
    var remaining: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag == .private_identifier) remaining += 1;
    }
    var ids = transformer.private_helper_symbol_ids.keyIterator();
    while (ids.next()) |id| {
        try std.testing.expect(id.* < edited.symbols.items.len);
        const symbol = edited.symbols.items[id.*];
        std.debug.print("PRIVATE_OUTPUT sid={d} storageScope={d} originScope={d} declaration={d}:{d}\n", .{ id.*, @backingInt(symbol.scope_id), @backingInt(symbol.origin_scope), symbol.declaration_span.start, symbol.declaration_span.end });
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != id.*) continue;
            std.debug.print("PRIVATE_REF sid={d} useScope={d} node={d} read={} write={} declare={}\n", .{ id.*, @backingInt(reference.scope_id), @backingInt(reference.node_index), reference.flags.read, reference.flags.write, reference.flags.declare });
        }
    }
    std.debug.print("PRIVATE_REMAINING count={d} source={s}\n", .{ remaining, source });
    return remaining;
}

test "escaped private source RED actual mapping and runtime controls" {
    const sources = [_][]const u8{
        "class C{#a=10;read(){return this.#a}}console.log(new C().read());",
        "class C{#\\u0061=10;read(){return this.#a}}console.log(new C().read());",
        "class C{#a=10;read(){return this.#\\u0061}}console.log(new C().read());",
        "class C{#\\u0061=10;read(){return this.#\\u0061}}console.log(new C().read());",
        "class A{#a=4;read(){return this.#a}}class B{#\\u0061=6;read(){return this.#a}}console.log(new A().read()+new B().read());",
        "class Outer{#a=4;read(){class Inner{#\\u0061=6;read(){return this.#a}}return this.#a+new Inner().read()}}console.log(new Outer().read());",
        "class C{#\\u0061=10;read(){return this.#a+(\"\\\\u0061\"===\"\\\\u0061\"?0:1)}}console.log(new C().read());",
        "class C{static #a=10;static read(){return this.#a}}console.log(C.read());",
        "class C{static #\\u0061=10;static read(){return this.#a}}console.log(C.read());",
        "class C{#\\u0061=0;read(){this.#a=4;this.#a++;return this.#a+=5}}console.log(new C().read());",
        "const _a=11,_a1=12;class C{#\\u0061=3;#b=7;read(){return [this.#a,this.#b].join(',')}bump(){this.#a++;return this.read()}}const c=new C();console.log(c.read()+'|'+c.bump()+'|'+_a+'|'+_a1);",
        "class C{#\\u0061=0;constructor(v){this.#a=v}read(other){return other.#a}}console.log(new C(0).read(new C(10)));",
    };
    var bad_ast: usize = 0;
    for (sources, 0..) |source, i| {
        const has_private_residue = (try privateSourceRedTuple(source)) != 0;
        if (has_private_residue) bad_ast += 1;
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        const expected_stdout = if (i == 10) "3,7|4,7|11|12\n" else "10\n";
        try std.testing.expectEqualStrings(expected_stdout, native.stdout);
        std.debug.print("PRIVATE_NATIVE case={d} stdout={s}\n", .{ i, native.stdout });
        // Retain the aggregate semantic failure before trying to emit an AST
        // already known to contain unlowered private syntax. This also keeps
        // a lookup-regression mutant from being counted as a codegen panic.
        if (has_private_residue) continue;
        var output_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer output_arena.deinit();
        const result = try @import("../transpile.zig").transpile(output_arena.allocator(), source, "private-values.js", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
        const actual = try std.process.run(output_arena.allocator(), std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        std.debug.print("PRIVATE_CODEGEN case={d} code={s}\nSTDERR={s}\n", .{ i, result.code, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    }
    std.debug.print("PRIVATE_RED_SUMMARY cases={d} badAST={d}\n", .{ sources.len, bad_ast });
    try std.testing.expectEqual(@as(usize, 0), bad_ast);
}

test "escaped private helper reservation source capture RED" {
    const sources = [_][]const u8{
        "const _a=10;class C{#\\u0061=_a;read(){return this.#a}}console.log(new C().read());",
        "const _\\u0061=10;class C{#a=_a;read(){return this.#a}}console.log(new C().read());",
    };
    var mismatches: usize = 0;
    for (sources, 0..) |source, i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("10\n", native.stdout);
        const result = try @import("../transpile.zig").transpile(a, source, "private-reservation.js", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        const matches = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
        if (!matches) mismatches += 1;
        std.debug.print("PRIVATE_RESERVATION case={d} source={s} code={s}\nstdout={s} stderr={s} match={}\n", .{ i, source, result.code, actual.stdout, actual.stderr, matches });
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "escaped private helper candidate decoder OOM preserves reservations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "const _a=10;class C{#\\u0061=_a;read(){return this.#a}}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var original_name: ?[]const u8 = null;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .property_definition) continue;
        const key_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").PropertyExtra.key];
        const key = parser.ast.nodes.items[key_raw];
        try std.testing.expect(key.tag == .private_identifier);
        original_name = parser.ast.getText(key.span);
    }
    const original = original_name orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("#\\u0061", original);
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var names = try es_helpers.PrivateNameAllocator.init(counting.allocator(), &parser.ast);
    defer names.deinit();
    const before = counting.alloc_index;
    const candidate = try names.makePrivateVarName(original);
    defer counting.allocator().free(candidate);
    const count = counting.alloc_index - before;
    try std.testing.expect(Scanner.identifierValueEquals(candidate, "_a2"));
    try std.testing.expect(count > 0);
    for (0..count) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var local = try es_helpers.PrivateNameAllocator.init(failing.allocator(), &parser.ast);
        defer local.deinit();
        const reserved_before = local.reserved.count();
        failing.fail_index = failing.alloc_index + offset;
        try std.testing.expectError(error.OutOfMemory, local.makePrivateVarName(original));
        try std.testing.expectEqual(reserved_before, local.reserved.count());
        try std.testing.expect(local.reserved.contains("_a"));
        try std.testing.expect(!local.reserved.contains("_a2"));
        try std.testing.expectEqualStrings("#\\u0061", original);
        failing.fail_index = std.math.maxInt(usize);
        const retry = try local.makePrivateVarName(original);
        defer failing.allocator().free(retry);
        try std.testing.expect(Scanner.identifierValueEquals(retry, "_a2"));
    }
    std.debug.print("PRIVATE_CANDIDATE_OOM actualParserKey={s} failures={d} initFailureInjection=false\n", .{ original, count });
}
