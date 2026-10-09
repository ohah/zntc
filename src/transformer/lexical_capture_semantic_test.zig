const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ast_walk = @import("../parser/ast_walk.zig");
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;

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
            var cursor: @import("../semantic/scope.zig").ScopeId = @enumFromInt(extracted);
            while (!cursor.isNone()) {
                if (@intFromEnum(cursor) == owner.value_ptr.*) {
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var this_count: usize = 0;
    var arguments_count: usize = 0;
    for (edited.symbols.items[old_symbols..], old_symbols..) |symbol, index| {
        const is_this = std.mem.startsWith(u8, symbol.synthetic_name, "_this");
        const is_arguments = std.mem.startsWith(u8, symbol.synthetic_name, "_arguments");
        if (!is_this and !is_arguments) continue;
        if (is_this) this_count += 1 else arguments_count += 1;
        try std.testing.expectEqual(enclosing, @intFromEnum(symbol.scope_id));
        const id: u32 = @intCast(index);
        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == id) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        var ref_count: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != index or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@intFromEnum(ref.node_index)));
            const reference_node = transformer.ast.getNode(ref.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, reference_node.tag);
            // Balanced reference counts can hide a `this`/`arguments` ID swap
            // if the checker follows spelling. Lock the name to this exact SID.
            try std.testing.expectEqualStrings(
                symbol.nameText(transformer.ast.source),
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
            try std.testing.expect(ref.flags.read);
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

fn checkNativeParameterNewTargetSymbols(source: []const u8) !void {
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var capture_ids: [2]u32 = undefined;
    var capture_scopes: [2]ScopeId = undefined;
    var captures: usize = 0;
    for (edited.symbols.items[original_symbols..], original_symbols..) |symbol, symbol_index| {
        if (!std.mem.startsWith(u8, symbol.synthetic_name, "_newTarget")) continue;
        try std.testing.expect(captures < capture_ids.len);
        // The outer source function may already bind `_newTarget`. These
        // factory parameters own separate nested scopes, so semantic naming
        // keeps the common placeholder and lets exact SymbolIds disambiguate.
        try std.testing.expectEqualStrings("_newTarget", symbol.synthetic_name);
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
            const owner_scope: ScopeId = @enumFromInt(owner.value_ptr.*);
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
            if (@intFromEnum(reference.symbol_id) != symbol_index or reference.node_index.isNone()) continue;
            if (!reference.flags.read and !reference.flags.write) continue;
            try std.testing.expect(live.contains(@intFromEnum(reference.node_index)));
            try std.testing.expectEqual(@as(?u32, @intCast(symbol_index)), edited.symbol_ids[@intFromEnum(reference.node_index)]);
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
    );
}

test "#4819 retained class parameter new.target factories keep exact pre-reanalysis symbols" {
    try checkNativeParameterNewTargetSymbols(
        "class Base { constructor(value = () => () => new.target) { this.target = value()(); } }",
    );
}

test "#4819 native parameter new.target factories reset exact owners at nested function boundaries" {
    try checkNativeParameterNewTargetSymbols(
        "function outer(value = () => function inner(read = () => () => new.target) { return read()(); }) { return value; }",
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
        .{ "class C{field=()=>this.x;constructor(){this.x=2;this.body=()=>this.x}} new C().field();", @as(u32, 2) },
        .{ "class C{field=()=>this.x;constructor(x=2){this.x=x}} new C().field();", @as(u32, 1) },
        .{ "class C{field=()=>this.x;x=2} new C().field();", @as(u32, 1) },
        .{ "class B{} class C extends B{field=()=>this.x;constructor(){super();this.x=2;this.body=()=>this.x}} new C().field();", @as(u32, 8) },
        .{ "class B{} class C extends B{field=()=>this.x;x=2} new C().field();", @as(u32, 4) },
        .{ "const C=class{field=()=>this.x;constructor(){this.x=2;this.body=()=>this.x}}; new C().field();", @as(u32, 2) },
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
            for (edited.references) |ref| {
                if (@intFromEnum(ref.symbol_id) != id or ref.node_index.isNone() or !live.contains(@intFromEnum(ref.node_index))) continue;
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
                reads += 1;
            }
            try std.testing.expectEqual(case[1], reads);
            try std.testing.expectEqual(case[1], symbol.reference_count);
        }
        try std.testing.expectEqual(@as(usize, 1), captures);
    }
}

test "#4819 explicit arguments binding moves to the exact capture initializer" {
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var capture_id: ?u32 = null;
    for (edited.symbols.items[old_count..], old_count..) |symbol, id| {
        if (!std.mem.startsWith(u8, symbol.synthetic_name, "_arguments")) continue;
        try std.testing.expect(capture_id == null);
        try std.testing.expectEqual(outer, @intFromEnum(symbol.scope_id));
        capture_id = @intCast(id);
    }
    const alias = capture_id orelse return error.TestUnexpectedResult;
    var source_reads: usize = 0;
    var alias_reads: usize = 0;
    for (edited.references) |ref| {
        if (ref.node_index.isNone() or !live.contains(@intFromEnum(ref.node_index))) continue;
        if (@intFromEnum(ref.symbol_id) == parameter_id) {
            try std.testing.expectEqual(outer, @intFromEnum(ref.scope_id));
            source_reads += 1;
        }
        if (@intFromEnum(ref.symbol_id) == alias) {
            try std.testing.expectEqual(arrow, @intFromEnum(ref.scope_id));
            alias_reads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), source_reads);
    try std.testing.expectEqual(@as(usize, 1), alias_reads);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[parameter_id].reference_count);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[alias].reference_count);
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var counts: [2][2]usize = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (edited.symbols.items[old_symbols..], old_symbols..) |symbol, id| {
        const kind: usize = if (std.mem.startsWith(u8, symbol.synthetic_name, "_this")) 0 else if (std.mem.startsWith(u8, symbol.synthetic_name, "_arguments")) 1 else continue;
        const scope_index: usize = if (@intFromEnum(symbol.scope_id) == function_scopes[0]) 0 else if (@intFromEnum(symbol.scope_id) == function_scopes[1]) 1 else return error.TestUnexpectedResult;
        counts[scope_index][kind] += 1;
        var bindings: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(id))) bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        var reads: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != id or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@intFromEnum(ref.node_index)));
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(@as(usize, 1), transformer.deferred_generator_loop_owners.count());

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| try live.put(allocator, raw, {});

    var this_count: usize = 0;
    var arguments_count: usize = 0;
    var common_scope: ?u32 = null;
    for (edited.symbols.items[old_symbols..], old_symbols..) |symbol, id| {
        const is_this = std.mem.startsWith(u8, symbol.synthetic_name, "_this");
        const is_arguments = std.mem.startsWith(u8, symbol.synthetic_name, "_arguments");
        if (!is_this and !is_arguments) continue;
        if (is_this) this_count += 1 else arguments_count += 1;
        const owner_scope = @intFromEnum(symbol.scope_id);
        if (common_scope) |existing| try std.testing.expectEqual(existing, owner_scope) else common_scope = owner_scope;
        try std.testing.expectEqual(source_scope, @intFromEnum(edited.scopes[owner_scope].parent));

        var binding_count: usize = 0;
        for (reachable) |raw| {
            if (transformer.ast.nodes.items[raw].tag == .binding_identifier and
                raw < edited.symbol_ids.len and edited.symbol_ids[raw] == @as(u32, @intCast(id))) binding_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);

        var read_count: usize = 0;
        for (edited.references) |ref| {
            if (@intFromEnum(ref.symbol_id) != id or ref.node_index.isNone()) continue;
            try std.testing.expect(live.contains(@intFromEnum(ref.node_index)));
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
