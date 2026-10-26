const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ast_walk = @import("../parser/ast_walk.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

const LiveArgumentReference = struct {
    node: @import("../parser/ast.zig").NodeIndex,
    id: u32,
    scope: ScopeId,
    flags: @import("../semantic/symbol.zig").ReferenceFlags,
};

fn checkLiveArgumentsBeforeFinish(t: *Transformer, source_symbols: []const @import("../semantic/symbol.zig").Symbol) ![]LiveArgumentReference {
    const a = t.allocator;
    const root = t.ast.transformed_root orelse return error.MissingTransformedRoot;
    const utils = @import("output_scope_test_utils.zig");
    var parents = try utils.buildParentMap(a, t.ast, root);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    if (t.outputOwnedScope(root)) |scope| try owners.put(a, @backingInt(root), @backingInt(scope));
    var live_nodes = parents.keyIterator();
    while (live_nodes.next()) |raw| {
        if (t.outputOwnedScope(@fromBackingInt(raw.*))) |scope| try owners.put(a, raw.*, @backingInt(scope));
    }
    var snapshots: std.ArrayList(LiveArgumentReference) = .empty;
    var cells = t.live_arguments_cells.iterator();
    while (cells.next()) |entry| {
        const id = entry.key_ptr.*;
        const cell = entry.value_ptr;
        const editor = &t.semantic_editor.?;
        try std.testing.expect(id < source_symbols.len);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SyntheticKind.implicit_arguments, source_symbols[id].synthetic_kind.?);
        try std.testing.expectEqual(source_symbols[id].scope_id, cell.scope);
        try std.testing.expectEqual(cell.scope, editor.symbols.items[id].scope_id);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, editor.symbols.items[id].kind);
        try std.testing.expect(@backingInt(cell.engine_id) >= source_symbols.len);
        const engine = editor.symbols.items[@backingInt(cell.engine_id)];
        try std.testing.expectEqual(cell.scope, engine.scope_id);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, engine.kind);
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SyntheticKind.implicit_arguments, engine.synthetic_kind.?);
        try std.testing.expectEqual(@as(?usize, @backingInt(cell.engine_id)), editor.scope_maps.items[cell.scope.toIndex()].get("arguments"));
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, editor.scopes.items[cell.scope.toIndex()].kind);
        var bindings: usize = 0;
        var engine_reads: usize = 0;
        var initializer_reads: usize = 0;
        var forwarding_reads: usize = 0;
        var expected_forwarding: usize = 0;
        var source_owners = t.scope_owner_map.iterator();
        while (source_owners.next()) |source_owner| {
            const raw = source_owner.key_ptr.*;
            if (source_owner.value_ptr.* != @backingInt(source_symbols[id].scope_id) or raw >= t.parser_node_count) continue;
            const original = t.ast.nodes.items[raw];
            const flags = switch (original.tag) {
                .function, .function_declaration, .function_expression => t.ast.readExtra(original.data.extra, @import("../parser/ast.zig").FunctionExtra.flags),
                .method_definition => @import("../parser/ast.zig").methodFlagsToFunctionFlags(t.ast.readExtra(original.data.extra, @import("../parser/ast.zig").MethodExtra.flags)),
                else => continue,
            };
            const FunctionFlags = @import("../parser/ast.zig").FunctionFlags;
            if (t.options.unsupported.async_generator and flags & (FunctionFlags.is_async | FunctionFlags.is_generator) == (FunctionFlags.is_async | FunctionFlags.is_generator)) {
                try std.testing.expectEqual(@as(usize, 0), expected_forwarding);
                expected_forwarding = 1;
            }
        }
        var cell_uses: usize = 0;
        live_nodes = parents.keyIterator();
        while (live_nodes.next()) |raw| {
            const node_id = t.getSymbolIdAt(@fromBackingInt(raw.*)) orelse continue;
            if (node_id != id and node_id != @backingInt(cell.engine_id)) continue;
            const node = t.ast.nodes.items[raw.*];
            const actual = utils.expectedScope(t.ast, root, &parents, &owners, raw.*) orelse return error.MissingActualCaptureScope;
            if (node.tag == .binding_identifier) {
                try std.testing.expectEqual(id, node_id);
                try std.testing.expectEqual(cell.scope, actual);
                bindings += 1;
                continue;
            }
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
            const reference = (try editor.referenceForNode(@fromBackingInt(raw.*))) orelse return error.MissingCaptureReferenceAtCreation;
            try std.testing.expectEqual(node_id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(actual, reference.scope_id);
            try std.testing.expect(reference.flags.read or reference.flags.write);
            if (node_id == @backingInt(cell.engine_id)) {
                try std.testing.expectEqual(cell.scope, actual);
                try std.testing.expect(reference.flags.read and !reference.flags.write);
                engine_reads += 1;
                const parent = t.ast.getNode(@fromBackingInt(parents.get(raw.*) orelse return error.MissingEngineReadParent));
                if (parent.tag == .variable_declarator and
                    @backingInt(t.ast.readExtraNode(parent.data.extra, 2)) == raw.* and
                    t.getSymbolIdAt(t.ast.readExtraNode(parent.data.extra, 0)) == id)
                {
                    initializer_reads += 1;
                } else if (parent.tag == .call_expression) {
                    const helper = t.runtime_helper_symbol_ids.get("__asyncGenerator") orelse return error.UnknownNativeEngineConsumer;
                    const callee = t.ast.readExtraNode(parent.data.extra, 0);
                    const args_start = t.ast.readExtra(parent.data.extra, 1);
                    try std.testing.expectEqual(@as(u32, 3), t.ast.readExtra(parent.data.extra, 2));
                    try std.testing.expectEqual(@as(?u32, @backingInt(helper)), t.getSymbolIdAt(callee));
                    try std.testing.expectEqual(raw.*, @backingInt(t.ast.readExtraNode(args_start, 1)));
                    forwarding_reads += 1;
                } else return error.UnknownNativeEngineConsumer;
            } else cell_uses += 1;
            try snapshots.append(a, .{ .node = @fromBackingInt(raw.*), .id = node_id, .scope = actual, .flags = reference.flags });
        }
        if (bindings == 0) std.debug.print("missing live arguments cell: sourceSID={d} scope={d} declaration={d} engineSID={d} engineReads={d} cellUses={d}\n", .{ id, @backingInt(cell.scope), @backingInt(cell.declaration), @backingInt(cell.engine_id), engine_reads, cell_uses });
        try std.testing.expectEqual(@as(usize, if (cell.source_has_binding) 2 else 1), bindings);
        try std.testing.expectEqual(@as(usize, 1), initializer_reads);
        try std.testing.expectEqual(expected_forwarding, forwarding_reads);
        try std.testing.expectEqual(1 + expected_forwarding, engine_reads);
        try std.testing.expect(cell_uses > 0);
    }
    return snapshots.toOwnedSlice(a);
}

fn checkLiveArgumentsAfterFinish(edited: anytype, snapshots: []const LiveArgumentReference) !void {
    for (snapshots) |snapshot| {
        try std.testing.expectEqual(snapshot.id, edited.symbol_ids[@backingInt(snapshot.node)].?);
        var found = false;
        for (edited.references) |reference| {
            if (reference.node_index != snapshot.node) continue;
            try std.testing.expect(!found);
            found = true;
            try std.testing.expectEqual(snapshot.id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(snapshot.scope, reference.scope_id);
            try std.testing.expectEqual(snapshot.flags, reference.flags);
        }
        try std.testing.expect(found);
    }
}

fn checkCaptureSymbolsWithUnsupported(
    source: []const u8,
    frame_tag: @import("../parser/ast.zig").Node.Tag,
    unsupported: @TypeOf(TransformOptions.compat.fromESTarget(.es5)),
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

    var outer_scope: ?u32 = null;
    var arrow_scope: ?u32 = null;
    var source_owners = analyzer.scope_owner_map.iterator();
    while (source_owners.next()) |owner| {
        const tag = parser.ast.nodes.items[owner.key_ptr.*].tag;
        if (tag == frame_tag) outer_scope = owner.value_ptr.*;
        if (tag == .arrow_function_expression) arrow_scope = owner.value_ptr.*;
    }
    const extracted = arrow_scope orelse return error.TestUnexpectedResult;
    if (frame_tag == .method_definition) {
        // A derived fixture also has a base constructor. Select the method
        // that lexically owns the source arrow, not map iteration order.
        var methods = analyzer.scope_owner_map.iterator();
        while (methods.next()) |owner| {
            if (parser.ast.nodes.items[owner.key_ptr.*].tag != .method_definition) continue;
            var cursor: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(@intCast(extracted));
            while (!cursor.isNone()) {
                if (@backingInt(cursor) == owner.value_ptr.*) {
                    outer_scope = owner.value_ptr.*;
                    break;
                }
                cursor = analyzer.scopes.items[cursor.toIndex()].parent;
            }
        }
    }
    const enclosing = outer_scope orelse return error.TestUnexpectedResult;
    const old_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = unsupported,
        .emit_runtime_helper_imports = true,
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
    const live_snapshots = try checkLiveArgumentsBeforeFinish(&transformer, analyzer.symbols.items);
    const edited = (try transformer.finishSemanticEdit()).?;
    try checkLiveArgumentsAfterFinish(edited, live_snapshots);

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var this_count: usize = 0;
    var arguments_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, index| {
        const is_this = index >= old_symbols and std.mem.startsWith(u8, symbol.synthetic_name, "_this");
        const is_live_arguments = transformer.live_arguments_cells.contains(@intCast(index));
        const is_arguments = is_live_arguments or (index >= old_symbols and std.mem.startsWith(u8, symbol.synthetic_name, "_arguments"));
        if (!is_this and !is_arguments) continue;
        if (is_this) this_count += 1 else arguments_count += 1;
        try std.testing.expectEqual(enclosing, @backingInt(symbol.scope_id));
        const id: u32 = @intCast(index);
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var ref_count: usize = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != index or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@backingInt(ref.node_index)));
            const reference_node = transformer.ast.getNode(ref.node_index);
            if (reference_node.tag == .assignment_target_identifier) {
                try std.testing.expect(is_this and !is_arguments);
                try std.testing.expectEqualDeep(@as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .write = true }), ref.flags);
            } else {
                try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, reference_node.tag);
                try std.testing.expect(ref.flags.read and !ref.flags.write);
            }
            // Balanced reference counts can hide a `this`/`arguments` ID swap
            // if the checker follows spelling. Lock the name to this exact SID.
            try std.testing.expectEqualStrings(
                if (is_live_arguments) transformer.block_rename_map.?.get(id).? else symbol.nameText(transformer.ast.source),
                transformer.ast.getText(reference_node.data.string_ref),
            );
            var use_scope = ref.scope_id;
            var resolves_capture = false;
            while (!use_scope.isNone()) {
                if (use_scope == symbol.scope_id) {
                    resolves_capture = true;
                    break;
                }
                use_scope = edited.scopes[use_scope.toIndex()].parent;
            }
            try std.testing.expect(resolves_capture);
            ref_count += 1;
        }
        try std.testing.expect(ref_count > 0);
        try std.testing.expectEqual(@as(u32, @intCast(ref_count)), symbol.reference_count);
    }
    try std.testing.expectEqual(@as(usize, 1), this_count);
    try std.testing.expectEqual(@as(usize, 1), arguments_count);
}

fn checkCaptureSymbols(source: []const u8, frame_tag: @import("../parser/ast.zig").Node.Tag) !void {
    try checkCaptureSymbolsWithUnsupported(
        source,
        frame_tag,
        TransformOptions.compat.fromESTarget(.es5),
    );
}

fn checkNativeParameterNewTargetSymbols(source: []const u8, expected_name: []const u8) !void {
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

    const original_symbols = analyzer.symbols.items.len;
    const unsupported = TransformOptions.compat.fromReactNativeVersion(0, 80);
    // Match the RN 0.80 matrix: native default parameters/classes, but arrows
    // and new.target are lowered. This audits generated symbols before bundler
    // reanalysis can repair them.
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = unsupported,
        .emit_runtime_helper_imports = true,
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
    const live_snapshots = try checkLiveArgumentsBeforeFinish(&transformer, analyzer.symbols.items);
    const edited = (try transformer.finishSemanticEdit()).?;
    try checkLiveArgumentsAfterFinish(edited, live_snapshots);

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var capture_ids: [2]u32 = undefined;
    var capture_scopes: [2]ScopeId = undefined;
    var captures: usize = 0;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, symbol_index| {
        if (!std.mem.startsWith(u8, symbol.synthetic_name, "_newTarget")) continue;
        try std.testing.expect(captures < capture_ids.len);
        // The generated parameter encloses the returned arrow, so reusing a
        // source `_newTarget` spelling would shadow the user's binding there.
        // Nested factories may share a safe placeholder; exact SymbolIds keep
        // their bindings and references distinct.
        try std.testing.expectEqualStrings(expected_name, symbol.synthetic_name);
        capture_ids[captures] = @intCast(symbol_index);
        capture_scopes[captures] = symbol.scope_id;
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqual(
            @as(?usize, symbol_index),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );

        var returned_arrow_scope_is_child = false;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |owner| {
            const owner_node = transformer.ast.nodes.items[owner.key_ptr.*];
            if (owner_node.tag != .function_expression) continue;
            const owner_scope: ScopeId = @fromBackingInt(@intCast(owner.value_ptr.*));
            if (owner_scope == symbol.scope_id or owner_scope.isNone()) continue;
            if (edited.scopes[owner_scope.toIndex()].parent == symbol.scope_id) {
                returned_arrow_scope_is_child = true;
                break;
            }
        }
        try std.testing.expect(returned_arrow_scope_is_child);

        var bindings: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(symbol_index)))
            {
                bindings += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);

        var references: usize = 0;
        for (edited.references) |reference| {
            if (@backingInt(reference.symbol_id) != symbol_index or reference.node_index.isNone()) continue;
            if (!reference.flags.read and !reference.flags.write) continue;
            try std.testing.expect(live.contains(@backingInt(reference.node_index)));
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@backingInt(reference.node_index)]);
            var scope = reference.scope_id;
            var resolves = false;
            while (!scope.isNone()) {
                if (scope == symbol.scope_id) {
                    resolves = true;
                    break;
                }
                scope = edited.scopes[scope.toIndex()].parent;
            }
            try std.testing.expect(resolves);
            references += 1;
        }
        try std.testing.expect(references > 0);
        try std.testing.expectEqual(@as(u32, @intCast(references)), symbol.reference_count);
        captures += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), captures);
    try std.testing.expect(capture_ids[0] != capture_ids[1]);
    try std.testing.expect(capture_scopes[0] != capture_scopes[1]);
}

test "#4819 native parameter new.target factories retain exact pre-reanalysis symbols" {
    try checkNativeParameterNewTargetSymbols(
        "function outer(_newTarget = 11, value = () => () => new.target) { return value()(); } outer();",
        "_newTarget2",
    );
}

test "#4819 retained class parameter new.target factories keep exact pre-reanalysis symbols" {
    try checkNativeParameterNewTargetSymbols(
        "class Base { constructor(value = () => () => new.target) { this.target = value()(); } }",
        "_newTarget",
    );
}

test "#4819 native parameter new.target factories reset exact owners at nested function boundaries" {
    try checkNativeParameterNewTargetSymbols(
        "function outer(value = () => function inner(read = () => () => new.target) { return read()(); }) { return value; }",
        "_newTarget",
    );
}

test "#4819 lowered arrow lexical captures have distinct exact function symbols" {
    try checkCaptureSymbols(
        "function outer(){return ()=>this.x+arguments[0]} outer.call({x:2},3);",
        .function_declaration,
    );
}

test "#4819 ordinary function captures keep exact symbols with colliding local aliases" {
    try checkCaptureSymbols(
        "function outer(value){const _this=2;const _arguments=3;return ()=>this.x+arguments[0]+_this+_arguments} outer.call({x:10},7);",
        .function_declaration,
    );
}

test "#4819 class method capture producers bind exact symbols without a name rescan" {
    try checkCaptureSymbols(
        "class C{method(){return ()=>this.x+arguments[0]}} new C().method();",
        .method_definition,
    );
    try checkCaptureSymbols(
        "class C{method(value=(()=>this.x+arguments.length)()){return value}} new C().method();",
        .method_definition,
    );
    try checkCaptureSymbols(
        "function logged(value){return value} class C{@logged field=1;method(){return ()=>this.field+arguments.length}} new C().method();",
        .method_definition,
    );
    try checkCaptureSymbols(
        "function logged(value){return value} class Base{} class C extends Base{@logged field=1;constructor(){super();this.read=()=>this.field+arguments.length}} new C().read();",
        .method_definition,
    );
    try checkCaptureSymbols(
        "class C{async method(){await 0;return ()=>this.x+arguments[0]}} new C().method();",
        .method_definition,
    );
    try checkCaptureSymbols(
        "class C{*method(){yield ()=>this.x+arguments[0]}} new C().method();",
        .method_definition,
    );
}

test "#4819 extracted private method captures bind exact symbols without a name rescan" {
    try checkCaptureSymbols(
        "class C{ x=10; #read(value){const _this=2;const _arguments=3;return ()=>this.x+arguments[0]+_this+_arguments} run(value){return this.#read(value)()} } new C().run(7);",
        .method_definition,
    );
}

test "#4819 async-to-state-machine fallback captures bind exact symbols without a name rescan" {
    try checkCaptureSymbols(
        "async function outer(value){const _this=2;const _arguments=3;await 0;return ()=>this.x+arguments[0]+_this+_arguments} outer.call({x:2},3);",
        .function_declaration,
    );
}

test "#4819 lowerAsyncFunction binds captures in a generator-preserving mixed target" {
    var unsupported = TransformOptions.compat.fromESTarget(.es5);
    unsupported.generator = false;
    try std.testing.expect(unsupported.async_await);
    try std.testing.expect(!unsupported.generator);
    try std.testing.expect(unsupported.arrow);
    try checkCaptureSymbolsWithUnsupported(
        "async function outer(value){await 0;return ()=>this.x+arguments[0]} outer.call({x:2},3);",
        .function_declaration,
        unsupported,
    );
}

test "#4819 mixed async-generator wrapper captures bind at declaration without a name rescan" {
    var unsupported = TransformOptions.compat.fromESTarget(.es5);
    unsupported.async_generator = false;
    try checkCaptureSymbolsWithUnsupported(
        "class C{async *method(value){yield ()=>this.x+arguments[0]}} new C().method(5);",
        .method_definition,
        unsupported,
    );
}

test "#4819 async-generator function wrapper binds parameter captures to exact symbols" {
    var unsupported = TransformOptions.compat.fromESTarget(.es5);
    unsupported.generator = false;
    try std.testing.expect(unsupported.async_generator);
    try std.testing.expect(!unsupported.generator);
    try std.testing.expect(unsupported.arrow);
    try checkCaptureSymbolsWithUnsupported(
        "async function* outer(value=()=>this.x+arguments.length){yield value()} outer.call({x:2});",
        .function_declaration,
        unsupported,
    );
}

test "#4819 extracted per-iteration generator captures bind to exact source symbols" {
    try checkCaptureSymbols(
        "function* outer(value){for(let i=0;i<2;i++){yield ()=>this.x+arguments[0]+i}} outer.call({x:2},3);",
        .function_declaration,
    );
}

test "#4819 downleveled class accessors keep exact this and arguments capture symbols" {
    try checkCaptureSymbols(
        "class C{get value(){return ()=>this.x+arguments[0]}} new C().value;",
        .method_definition,
    );
}

test "#4819 class field arrows share their exact constructor capture binding" {
    const cases = .{
        .{ "class C{field=()=>this.x;constructor(){this.x=2;this.body=()=>this.x}} new C().field();", @as(u32, 2), @as(u32, 0) },
        .{ "class C{field=()=>this.x;constructor(x=2){this.x=x}} new C().field();", @as(u32, 1), @as(u32, 0) },
        .{ "class C{field=()=>this.x;x=2} new C().field();", @as(u32, 1), @as(u32, 0) },
        .{ "class B{} class C extends B{field=()=>this.x;constructor(){super();this.x=2;this.body=()=>this.x}} new C().field();", @as(u32, 8), @as(u32, 1) },
        .{ "class B{} class C extends B{field=()=>this.x;x=2} new C().field();", @as(u32, 4), @as(u32, 0) },
        .{ "const C=class{field=()=>this.x;constructor(){this.x=2;this.body=()=>this.x}}; new C().field();", @as(u32, 2), @as(u32, 0) },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, case[0]);
        var parser = Parser.init(allocator, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        const original_symbols = analyzer.symbols.items.len;
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
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;
        _ = try transformer.transform();
        try std.testing.expectEqual(@as(usize, 0), transformer.parameter_capture_statements.count());
        const edited = (try transformer.finishSemanticEdit()).?;
        const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
        var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (reachable) |raw| try live.put(allocator, raw, {});
        var captures: usize = 0;
        for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, id| {
            if (!std.mem.startsWith(u8, symbol.synthetic_name, "_this")) continue;
            captures += 1;
            try std.testing.expectEqual(@as(@import("../semantic/scope.zig").ScopeKind, .function), edited.scopes[symbol.scope_id.toIndex()].kind);
            var bindings: usize = 0;
            for (reachable) |raw| {
                if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                    raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(id))) bindings += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), bindings);
            var reads: u32 = 0;
            var writes: u32 = 0;
            for (edited.references) |ref| {
                if (@backingInt(ref.symbol_id) != id or ref.node_index.isNone() or !live.contains(@backingInt(ref.node_index))) continue;
                var scope = ref.scope_id;
                var visible = false;
                while (!scope.isNone()) {
                    if (scope == symbol.scope_id) {
                        visible = true;
                        break;
                    }
                    scope = edited.scopes[scope.toIndex()].parent;
                }
                try std.testing.expect(visible);
                if (ref.flags.write) {
                    try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.assignment_target_identifier, transformer.ast.getNode(ref.node_index).tag);
                    try std.testing.expect(!ref.flags.read);
                    writes += 1;
                } else {
                    try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, transformer.ast.getNode(ref.node_index).tag);
                    try std.testing.expect(ref.flags.read);
                    reads += 1;
                }
            }
            try std.testing.expectEqual(case[1], reads);
            try std.testing.expectEqual(case[2], writes);
            try std.testing.expectEqual(case[1] + case[2], symbol.reference_count);
            try std.testing.expectEqual(case[2], symbol.write_count);
        }
        try std.testing.expectEqual(@as(usize, 1), captures);
    }
}

test "#4819 explicit arguments binding keeps one live identity through the lowered arrow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function outer(arguments){return ()=>arguments} outer(3)();";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var function_scope: ?u32 = null;
    var arrow_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        switch (parser.ast.nodes.items[owner.key_ptr.*].tag) {
            .function_declaration => function_scope = owner.value_ptr.*,
            .arrow_function_expression => arrow_scope = owner.value_ptr.*,
            else => {},
        }
    }
    const outer = function_scope orelse return error.TestUnexpectedResult;
    const arrow = arrow_scope orelse return error.TestUnexpectedResult;
    const parameter_id: u32 = @intCast(analyzer.scope_maps.items[outer].get("arguments").?);
    const old_count = analyzer.symbols.items.len;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const live_snapshots = try checkLiveArgumentsBeforeFinish(&transformer, analyzer.symbols.items);
    const edited = (try transformer.finishSemanticEdit()).?;
    try checkLiveArgumentsAfterFinish(edited, live_snapshots);
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    // This is the source parameter's live binding, not a value snapshot.
    // Its selected output spelling avoids the generated function's implicit
    // arguments binding while every use keeps the original parameter SID.
    try std.testing.expectEqual(old_count, edited.symbols.items.len);
    try std.testing.expectEqual(outer, @backingInt(edited.symbols.items[parameter_id].scope_id));
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, edited.symbols.items[parameter_id].kind);
    var parameter_bindings: usize = 0;
    for (reachable) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .binding_identifier or edited.symbol_ids[raw] != parameter_id) continue;
        const selected = transformer.block_rename_map.?.get(parameter_id) orelse return error.MissingSelectedArgumentsAlias;
        try std.testing.expect(!std.mem.eql(u8, selected, "arguments"));
        try std.testing.expectEqualStrings(selected, transformer.ast.getText(transformer.ast.nodes.items[raw].data.string_ref));
        parameter_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), parameter_bindings);
    var live_reads: usize = 0;
    for (edited.references) |ref| {
        if (ref.node_index.isNone() or !live.contains(@backingInt(ref.node_index)) or @backingInt(ref.symbol_id) != parameter_id) continue;
        try std.testing.expectEqual(arrow, @backingInt(ref.scope_id));
        try std.testing.expect(ref.flags.read and !ref.flags.write);
        live_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live_reads);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[parameter_id].reference_count);
    try std.testing.expectEqual(@as(u32, 0), edited.symbols.items[parameter_id].write_count);
}

test "#4819 nested source functions keep distinct capture symbol IDs and scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        "function outer(_this,_arguments){" ++
        "const first=()=>this.base+arguments.length;" ++
        "function inner(_this,_arguments){return ()=>this.base+arguments.length;}" ++
        "return first()+inner.call({base:5},1);}";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var function_scopes: [2]u32 = undefined;
    var function_count: usize = 0;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        if (parser.ast.nodes.items[owner.key_ptr.*].tag != .function_declaration) continue;
        try std.testing.expect(function_count < function_scopes.len);
        function_scopes[function_count] = owner.value_ptr.*;
        function_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), function_count);
    const old_symbols = analyzer.symbols.items.len;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const live_snapshots = try checkLiveArgumentsBeforeFinish(&transformer, analyzer.symbols.items);
    const edited = (try transformer.finishSemanticEdit()).?;
    try checkLiveArgumentsAfterFinish(edited, live_snapshots);
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var counts: [2][2]usize = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (edited.symbols.items, 0..) |symbol, id| {
        const kind: usize = if (id >= old_symbols and std.mem.startsWith(u8, symbol.synthetic_name, "_this")) 0 else if (transformer.live_arguments_cells.contains(@intCast(id)) or (id >= old_symbols and std.mem.startsWith(u8, symbol.synthetic_name, "_arguments"))) 1 else continue;
        const scope_index: usize = if (@backingInt(symbol.scope_id) == function_scopes[0]) 0 else if (@backingInt(symbol.scope_id) == function_scopes[1]) 1 else return error.TestUnexpectedResult;
        counts[scope_index][kind] += 1;
        var bindings: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(id))) bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        var reads: usize = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != id or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@backingInt(ref.node_index)));
            var scope = ref.scope_id;
            var sees_owner = false;
            while (!scope.isNone()) {
                if (scope == symbol.scope_id) {
                    sees_owner = true;
                    break;
                }
                scope = edited.scopes[scope.toIndex()].parent;
            }
            try std.testing.expect(sees_owner);
            reads += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), reads);
        try std.testing.expectEqual(@as(u32, 1), symbol.reference_count);
    }
    try std.testing.expectEqualDeep([2][2]usize{ .{ 1, 1 }, .{ 1, 1 } }, counts);
}

test "#4819 extracted async generator loop retains source lexical capture owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "async function* collect(items){for await(const item of items){yield (()=>this.base+arguments.length+item)();}}";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var source_function_scope: ?u32 = null;
    var owners = analyzer.scope_owner_map.iterator();
    while (owners.next()) |owner| {
        if (parser.ast.nodes.items[owner.key_ptr.*].tag == .function_declaration)
            source_function_scope = owner.value_ptr.*;
    }
    const source_scope = source_function_scope orelse return error.TestUnexpectedResult;
    const old_symbols = analyzer.symbols.items.len;

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
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const live_snapshots = try checkLiveArgumentsBeforeFinish(&transformer, analyzer.symbols.items);
    const edited = (try transformer.finishSemanticEdit()).?;
    try checkLiveArgumentsAfterFinish(edited, live_snapshots);
    try std.testing.expectEqual(@as(usize, 1), transformer.deferred_generator_loop_owners.count());

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var this_count: usize = 0;
    var arguments_count: usize = 0;
    var common_scope: ?u32 = null;
    for (edited.symbols.items, 0..) |symbol, id| {
        const is_this = id >= old_symbols and std.mem.startsWith(u8, symbol.synthetic_name, "_this");
        const is_live_arguments = transformer.live_arguments_cells.contains(@intCast(id));
        const is_arguments = is_live_arguments or (id >= old_symbols and std.mem.startsWith(u8, symbol.synthetic_name, "_arguments"));
        if (!is_this and !is_arguments) continue;
        if (is_this) this_count += 1 else arguments_count += 1;
        const owner_scope = @backingInt(symbol.scope_id);
        if (is_live_arguments) {
            try std.testing.expectEqual(source_scope, owner_scope);
        } else {
            if (common_scope) |existing| try std.testing.expectEqual(existing, owner_scope) else common_scope = owner_scope;
            try std.testing.expectEqual(source_scope, @backingInt(edited.scopes[owner_scope].parent));
        }

        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(id))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var read_count: usize = 0;
        for (edited.references) |ref| {
            if (@backingInt(ref.symbol_id) != id or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@backingInt(ref.node_index)));
            var cursor = ref.scope_id;
            var sees_capture = false;
            while (!cursor.isNone()) {
                if (cursor == symbol.scope_id) {
                    sees_capture = true;
                    break;
                }
                cursor = edited.scopes[cursor.toIndex()].parent;
            }
            try std.testing.expect(sees_capture);
            read_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), read_count);
        try std.testing.expectEqual(@as(u32, 1), symbol.reference_count);
    }
    try std.testing.expectEqual(@as(usize, 1), this_count);
    try std.testing.expectEqual(@as(usize, 1), arguments_count);
}

const NativeArrowBirthAst = @import("../parser/ast.zig");
const NativeArrowBirthWalker = struct {
    transformer: *Transformer,
    captures: []const u32,
    stack: std.ArrayList(u32) = .empty,
    reads: usize = 0,

    fn captureInScope(self: *@This(), scope: ScopeId) ?u32 {
        const editor = &self.transformer.semantic_editor.?;
        for (self.captures) |id| if (editor.symbols.items[id].scope_id == scope) return id;
        return null;
    }

    fn walk(self: *@This(), owner: NativeArrowBirthAst.NodeIndex, expected_scope: ScopeId, parent_function: ?u32, capture_argument: bool) anyerror!void {
        if (owner.isNone()) return;
        const transformer = self.transformer;
        const node = transformer.ast.getNode(owner);
        const editor = &transformer.semantic_editor.?;
        if (node.tag == .identifier_reference) {
            const name = transformer.ast.identifierNameText(node);
            var expected_symbol: ?u32 = null;
            var index = self.stack.items.len;
            while (index > 0) {
                index -= 1;
                const id = self.stack.items[index];
                if (std.mem.eql(u8, editor.symbols.items[id].synthetic_name, name)) {
                    expected_symbol = id;
                    break;
                }
            }
            if (expected_symbol == null and capture_argument) {
                if (parent_function) |id| {
                    const symbol = editor.symbols.items[id];
                    if (std.mem.eql(u8, symbol.nameText(transformer.ast.source), name)) expected_symbol = id;
                }
            }
            if (expected_symbol) |id| {
                const reference = (try editor.referenceForNode(owner)) orelse return error.NativeArrowReferenceNotCreated;
                try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(expected_scope, reference.scope_id);
                try std.testing.expect(reference.flags.read and !reference.flags.write and !reference.flags.declare);
                try std.testing.expectEqual(id, transformer.getSymbolIdAt(owner).?);
                self.reads += 1;
            }
        }
        switch (node.tag) {
            .function, .function_declaration, .function_expression, .arrow_function_expression, .method_definition => {
                const function_scope = transformer.outputOwnedScope(owner) orelse return error.NativeArrowFunctionScopeNotCreated;
                const is_arrow = node.tag == .arrow_function_expression;
                const parameters = transformer.ast.readExtraNode(node.data.extra, if (is_arrow) 0 else 1);
                const body = transformer.ast.readExtraNode(node.data.extra, if (is_arrow) 1 else 2);
                const parameter_scope = transformer.outputOwnedScope(parameters) orelse function_scope;
                const source = transformer.scope_owner_origins.get(@backingInt(owner)) orelse @backingInt(owner);
                const lowered_arrow = transformer.ast.nodes.items[source].tag == .arrow_function_expression;
                const capture = self.captureInScope(function_scope);
                if (capture != null or lowered_arrow) {
                    const lexical_root = if (parameter_scope != function_scope) parameter_scope else function_scope;
                    try std.testing.expectEqual(expected_scope, editor.scopes.items[lexical_root.toIndex()].parent);
                    if (parameter_scope != function_scope)
                        try std.testing.expectEqual(parameter_scope, editor.scopes.items[function_scope.toIndex()].parent);
                }
                var function_identity = parent_function;
                if (capture == null and !lowered_arrow) {
                    function_identity = if (node.tag == .method_definition) null else transformer.getSymbolIdAt(transformer.ast.readExtraNode(node.data.extra, 0));
                }
                const old_len = self.stack.items.len;
                if (capture) |id| try self.stack.append(transformer.allocator, id);
                defer self.stack.shrinkRetainingCapacity(old_len);
                try self.walk(parameters, parameter_scope, function_identity, false);
                try self.walk(body, function_scope, function_identity, false);
                return;
            },
            .call_expression => {
                const callee = transformer.ast.readExtraNode(node.data.extra, 0);
                const callee_scope = transformer.outputOwnedScope(callee);
                const wrapper_call = if (callee_scope) |scope| self.captureInScope(scope) != null else false;
                try self.walk(callee, expected_scope, parent_function, capture_argument);
                const start = transformer.ast.readExtra(node.data.extra, 1);
                const len = transformer.ast.readExtra(node.data.extra, 2);
                for (transformer.ast.extra_data.items[start .. start + len]) |argument|
                    try self.walk(@fromBackingInt(argument), expected_scope, parent_function, capture_argument or wrapper_call);
                return;
            },
            else => {},
        }
        const scope = transformer.outputOwnedScope(owner) orelse expected_scope;
        var children = ast_walk.children(transformer.ast, node);
        while (children.next()) |child| try self.walk(child, scope, parent_function, capture_argument);
    }
};

fn checkNativeArrowReferenceBirth(source: []const u8, expected_captures: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromReactNativeVersion(0, 80) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const original_symbols = analyzer.symbols.items.len;
    try transformer.buildBlockRenameMap();
    try @import("parameter_environment.zig").collectClassInferredNames(&transformer);
    try @import("native_parameter_cells.zig").normalize(&transformer);
    const source_root: NativeArrowBirthAst.NodeIndex = @fromBackingInt(@as(u32, @intCast(transformer.parser_node_count - 1)));
    const root = try transformer.visitNode(source_root);
    // No generic function registration, output scope walk or finish has run.
    const editor = &transformer.semantic_editor.?;
    var captures: std.ArrayList(u32) = .empty;
    for (editor.symbols.items[original_symbols..], original_symbols..) |symbol, raw| {
        if (symbol.kind != .parameter or !std.mem.startsWith(u8, symbol.synthetic_name, "_newTarget")) continue;
        try captures.append(allocator, @intCast(raw));
        try std.testing.expect(!symbol.scope_id.isNone());
    }
    try std.testing.expectEqual(expected_captures, captures.items.len);
    var walker: NativeArrowBirthWalker = .{ .transformer = &transformer, .captures = captures.items };
    try walker.walk(root, @fromBackingInt(0), null, false);
    try std.testing.expect(walker.reads >= expected_captures);
}

test "native parameter arrow references and lexical scopes exist before finalization" {
    try checkNativeArrowReferenceBirth("function Parent(get=()=>new.target){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=()=>class extends(new.target||Object){}){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=()=>class{[new.target===Parent?'yes':'no'](){return 7}}){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=([read=()=>new.target]=[])=>read){return get}", 2);
    try checkNativeArrowReferenceBirth("function Parent(get=({read=()=>new.target}={})=>read){return get}", 2);
    try checkNativeArrowReferenceBirth("function Parent(get=(value=new.target)=>value){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=()=>()=>new.target){return get}", 2);
    try checkNativeArrowReferenceBirth("function Parent(get=(read=()=>new.target)=>read){return get}", 2);
    try checkNativeArrowReferenceBirth("function Parent(get=(value=new.target)=>()=>value){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(_newTarget=11,get=()=>[new.target,_newTarget]){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=(_newTarget=11)=>[new.target,_newTarget]){return get}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=()=>{let local=1;{const value=new.target;return[value,local]}}){return get}", 1);
    try checkNativeArrowReferenceBirth("class Base{}class Box extends Base{constructor(get=()=>new.target){super();this.get=get}}", 1);
    try checkNativeArrowReferenceBirth("function Parent(get=()=>function Own(){return new.target}){return get}", 0);
    try checkNativeArrowReferenceBirth("function Parent(__proto__=()=>new.target){return __proto__}", 1);
    try checkNativeArrowReferenceBirth("function Parent(_newTarget=11,get=()=>{eval('1');return new.target}){return get}", 1);
}

const FieldInitializerBirthWalker = struct {
    transformer: *Transformer,
    outside_symbol: u32,
    reads: usize = 0,
    import_provenance: usize = 0,
    parameters: std.ArrayList(struct { id: u32, scope: ScopeId, name: []const u8 }) = .empty,

    fn walk(self: *@This(), owner: NativeArrowBirthAst.NodeIndex, expected_scope: ScopeId) anyerror!void {
        if (owner.isNone()) return;
        const t = self.transformer;
        const node = t.ast.getNode(owner);
        const scopes = if (t.semantic_editor) |*editor| editor.scopes.items else t.scopes;
        var expected_id: ?u32 = null;
        if (node.tag == .identifier_reference) {
            if (t.getSymbolIdAt(owner) == self.outside_symbol) expected_id = self.outside_symbol;
            for ([_][]const u8{ "__publicField", "__name" }) |helper_name| {
                if (t.runtime_helper_symbol_ids.get(helper_name)) |helper| {
                    if (t.getSymbolIdAt(owner) == @backingInt(helper)) expected_id = @backingInt(helper);
                }
            }
            for (self.parameters.items) |parameter| {
                if (parameter.scope == expected_scope and std.mem.eql(u8, parameter.name, t.ast.identifierNameText(node))) expected_id = parameter.id;
            }
        }
        if (expected_id) |id| {
            const found = if (t.semantic_editor) |*editor| try editor.referenceForNode(owner) else blk: {
                for (t.references) |reference| if (reference.node_index == owner) break :blk reference;
                break :blk null;
            };
            const reference = found orelse return error.FieldInitializerReferenceNotCreated;
            try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(expected_scope, reference.scope_id);
            try std.testing.expect(reference.flags.read and !reference.flags.write);
            if (id == self.outside_symbol) self.reads += 1;
        }
        if (node.tag == .import_expression) {
            const provenance = t.transformed_node_scope_provenance.get(owner) orelse
                t.node_scope_provenance.get(owner) orelse return error.FieldInitializerImportProvenanceNotCreated;
            try std.testing.expectEqual(expected_scope, provenance.scope);
            try std.testing.expect(@backingInt(provenance.source_node) < t.parser_node_count);
            try std.testing.expectEqual(NativeArrowBirthAst.Node.Tag.import_expression, t.ast.getNode(provenance.source_node).tag);
            self.import_provenance += 1;
        }
        switch (node.tag) {
            .function, .function_declaration, .function_expression, .arrow_function_expression, .method_definition => {
                const scope = t.outputOwnedScope(owner) orelse return error.FieldInitializerFunctionScopeNotCreated;
                const arrow = node.tag == .arrow_function_expression;
                const parameters = t.ast.readExtraNode(node.data.extra, if (arrow) 0 else 1);
                const body = t.ast.readExtraNode(node.data.extra, if (arrow) 1 else 2);
                const parameter_scope = t.outputOwnedScope(parameters) orelse scope;
                const root = if (parameter_scope != scope) parameter_scope else scope;
                try std.testing.expectEqual(expected_scope, scopes[root.toIndex()].parent);
                if (parameter_scope != scope) try std.testing.expectEqual(parameter_scope, scopes[scope.toIndex()].parent);
                const old_parameters = self.parameters.items.len;
                defer self.parameters.shrinkRetainingCapacity(old_parameters);
                if (@backingInt(owner) >= t.parser_node_count and node.tag == .method_definition) {
                    const list = t.ast.getNode(parameters).data.list;
                    for (t.ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
                        const parameter = t.ast.nodes.items[raw];
                        if (parameter.tag != .rest_element) continue;
                        const binding = parameter.data.unary.operand;
                        const id = t.getSymbolIdAt(binding) orelse return error.FieldInitializerParameterIdNotCreated;
                        const symbols = if (t.semantic_editor) |*editor| editor.symbols.items else t.symbols;
                        try std.testing.expectEqual(parameter_scope, symbols[id].scope_id);
                        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, symbols[id].kind);
                        try self.parameters.append(t.allocator, .{ .id = id, .scope = parameter_scope, .name = t.ast.identifierNameText(t.ast.getNode(binding)) });
                    }
                }
                try self.walk(parameters, parameter_scope);
                try self.walk(body, scope);
                return;
            },
            .class_declaration, .class_expression => {
                const scope = t.outputOwnedScope(owner) orelse return error.FieldInitializerClassScopeNotCreated;
                try std.testing.expectEqual(expected_scope, scopes[scope.toIndex()].parent);
            },
            else => {},
        }
        const scope = t.outputOwnedScope(owner) orelse expected_scope;
        var children = ast_walk.children(t.ast, node);
        while (children.next()) |child| try self.walk(child, scope);
    }
};

fn checkFieldInitializerReferenceBirth(source: []const u8) !void {
    try checkFieldInitializerReferenceBirthWithDefine(source, false);
    try checkFieldInitializerReferenceBirthWithDefine(source, true);
}

fn checkFieldInitializerReferenceBirthWithDefine(source: []const u8, define: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var outside: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (symbol.scope_id == @as(ScopeId, @fromBackingInt(0)) and std.mem.eql(u8, symbol.nameText(parser.ast.source), "outside")) outside = @intCast(id);
    }
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = define,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    try transformer.buildBlockRenameMap();
    try @import("parameter_environment.zig").collectClassInferredNames(&transformer);
    try @import("native_parameter_cells.zig").normalize(&transformer);
    const root = try transformer.visitNode(@fromBackingInt(@as(u32, @intCast(transformer.parser_node_count - 1))));
    var walker: FieldInitializerBirthWalker = .{ .transformer = &transformer, .outside_symbol = outside.? };
    try walker.walk(root, @fromBackingInt(0));
    // Expression provenance is checked independently: the original analyzer
    // still omits import argument references (separate mandatory producer gap).
    try std.testing.expect(walker.reads > 0 or walker.import_provenance > 0);
}

test "field initializer implicit constructor scope exists before finalization" {
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=outside}");
}

test "field initializer existing constructor references use actual scope before finalization" {
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=outside;constructor(){this.body=1}}");
}

test "field initializer arrow frontier uses actual constructor before finalization" {
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=()=>outside;constructor(){this.body=1}}");
}

test "field initializer constructor and lexical frontier inventory exists before finalization" {
    try checkFieldInitializerReferenceBirth("const outside=7;class Base{}class Box extends Base{value=outside}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Base{}class Box extends Base{value=outside;constructor(){super();this.body=1}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{#value=outside;read(){return this.#value}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=function(){return outside};constructor(){this.body=1}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=class Inner{read(){return outside}};constructor(){this.body=1}}");
    try checkFieldInitializerReferenceBirth("const outside=7;const Box=class{value=()=>outside}");
    try checkFieldInitializerReferenceBirth("const key='value';const outside=7;class Box{[key]=outside;constructor(){this.body=1}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=()=>outside;constructor(outside=1){this.body=outside}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=()=>outside;constructor(outside){this.body=outside}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=()=>outside;constructor(){var outside=9;this.body=outside}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=outside;constr\\u0075ctor(){this.body=1}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=outside;['constructor'](){return outside}}");
}

test "field initializer actual constructor roles and blank define field scope exist before finalization" {
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=outside;'constructor'(){this.body=1}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{value=outside;static constructor(){return 2}}");
    try checkFieldInitializerReferenceBirth("const outside=7;class Box{empty;read(){return outside}}");
}

test "field initializer direct import and nested import provenance exists before finalization" {
    try checkFieldInitializerReferenceBirth("const outside='node:os';class Box{value=import(outside);constructor(){}}");
    try checkFieldInitializerReferenceBirth("const outside='node:os';class Box{value=()=>import(outside);constructor(outside){this.body=outside}}");
    try checkFieldInitializerReferenceBirth("const outside='node:os';class Box{value=class Inner{read(){return import(outside)}};constructor(){}}");
}
