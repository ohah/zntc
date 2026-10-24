const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const ast_walk = @import("../parser/ast_walk.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const coverage = @import("symbol_coverage.zig");

fn expectStaticCaptureIdentity(
    source: []const u8,
    lower_class: bool,
    expected_captures: usize,
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
        .unsupported = TransformOptions.compat.fromESTarget(if (lower_class) .es5 else .es2015),
        .use_define_for_class_fields = true,
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
    const report = try coverage.checkStrictWithExactExternalEvidence(
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
    try std.testing.expect(report.isConsistent());
    try std.testing.expect(report.hasCompleteSymbolIdentity());

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    var capture_count: usize = 0;
    var staging_names: std.StringHashMapUnmanaged(void) = .empty;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (!std.mem.startsWith(u8, symbol.synthetic_name, "_classThis")) continue;
        capture_count += 1;
        try std.testing.expect(!staging_names.contains(symbol.synthetic_name));
        try staging_names.put(allocator, symbol.synthetic_name, {});
        try std.testing.expectEqual(if (lower_class) @import("../semantic/symbol.zig").SymbolKind.variable_var else .variable_const, symbol.kind);
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expectEqual(@as(?usize, raw_id), edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name));
        var bindings: usize = 0;
        var exact_reads: usize = 0;
        for (reachable) |raw| {
            if (raw >= edited.symbol_ids.len or edited.symbol_ids[raw] != @as(?u32, @intCast(raw_id))) continue;
            const node = transformer.ast.nodes.items[raw];
            if (node.tag == .binding_identifier) bindings += 1;
            if (node.tag == .identifier_reference) {
                var recorded = false;
                for (edited.references) |reference| {
                    if (@backingInt(reference.node_index) != raw) continue;
                    try std.testing.expectEqual(@as(u32, @intCast(raw_id)), @backingInt(reference.symbol_id));
                    try std.testing.expect(reference.flags.read and !reference.flags.write);
                    recorded = true;
                }
                try std.testing.expect(recorded);
                exact_reads += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expect(exact_reads > 0);
    }
    try std.testing.expectEqual(expected_captures, capture_count);
    // Later bundler syntax passes must preserve the producer's readonly
    // contract while leaving ordinary source declarations eligible for var.
    const preserved = transformer.ast.preserve_lexical_declaration_indices.items;
    const original_kinds = try allocator.alloc(@import("../parser/ast.zig").VariableDeclarationKind, preserved.len);
    for (preserved, 0..) |raw, i| original_kinds[i] = transformer.ast.variableDeclarationKind(transformer.ast.nodes.items[raw]);
    @import("minify.zig").downgradeToVar(transformer.ast);
    @import("minify.zig").convertConstToLetPreserving(transformer.ast, preserved);
    for (preserved, original_kinds) |raw, original_kind| {
        try std.testing.expect(original_kind == .let or original_kind == .@"const");
        try std.testing.expectEqual(original_kind, transformer.ast.variableDeclarationKind(transformer.ast.nodes.items[raw]));
    }
    var private_bindings: usize = 0;
    for (edited.symbols.items) |symbol| {
        if (!std.mem.eql(u8, symbol.synthetic_name, "_value")) continue;
        private_bindings += 1;
        try std.testing.expectEqual(if (lower_class) @import("../semantic/symbol.zig").SymbolKind.variable_var else .variable_let, symbol.kind);
        if (!lower_class and std.mem.startsWith(u8, source, "for"))
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, edited.scopes[symbol.scope_id.toIndex()].kind);
    }
    if (std.mem.indexOf(u8, source, "#value") != null) {
        try std.testing.expect(private_bindings > 0);
        if (!lower_class) {
            var lexical_private_storage: usize = 0;
            for (original_kinds) |kind| {
                if (kind == .let) lexical_private_storage += 1;
            }
            try std.testing.expect(lexical_private_storage >= private_bindings);
        }
    }
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .variable_declaration) continue;
        const declarations = @import("../parser/ast.zig").NodeList{
            .start = transformer.ast.extra_data.items[node.data.extra + 1],
            .len = transformer.ast.extra_data.items[node.data.extra + 2],
        };
        var iterator = transformer.ast.iterateExtraList(declarations);
        while (iterator.next()) |declarator| {
            const name = transformer.ast.readExtraNode(transformer.ast.getNode(declarator).data.extra, 0);
            const binding = transformer.ast.getNode(name);
            if (binding.tag == .binding_identifier and std.mem.eql(u8, transformer.ast.getText(binding.data.string_ref), "_ordinary"))
                try std.testing.expectEqual(@import("../parser/ast.zig").VariableDeclarationKind.@"var", transformer.ast.variableDeclarationKind(node));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.static_class_contexts.items.len);
    try std.testing.expectEqual(@as(u32, 0), transformer.static_class_captures.count());
}

test "#4819 static class capture producer owns immutable native and per-evaluation lowered bindings" {
    const source = "const _ordinary = 1; class Box { static read = () => this === Box; }";
    try expectStaticCaptureIdentity(source, false, 1);
    try expectStaticCaptureIdentity(source, true, 1);
}

test "#4819 static class capture separates nested owners before final output naming" {
    const source = "class Box { static make = () => { class Box { static read = () => this; } return [this, Box.read()]; }; }";
    try expectStaticCaptureIdentity(source, false, 2);
    try expectStaticCaptureIdentity(source, true, 2);
}

test "#4819 static class capture reserves named expression owner before visiting initializer" {
    const source = "const Outer = class Inner { static read = () => this === Inner; };";
    try expectStaticCaptureIdentity(source, false, 1);
    try expectStaticCaptureIdentity(source, true, 1);
}

test "#4819 static class capture attaches exact identity before output reconciliation" {
    const source = "class Box { static read = () => this; }";
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
        .use_define_for_class_fields = true,
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

    const ast = @import("../parser/ast.zig");
    var owner: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) {
            owner = @fromBackingInt(@intCast(@as(u32, @intCast(raw))));
            break;
        }
    }
    try std.testing.expect(!owner.isNone());
    const binding = parser.ast.readExtraNode(parser.ast.getNode(owner).data.extra, ast.ClassExtra.name);
    const self_id = analyzer.class_self_symbol_map.get(@backingInt(owner)).?;
    transformer.current_class_name_node = binding;
    transformer.current_class_self_symbol_id = self_id;
    transformer.current_scope = analyzer.symbols.items[self_id].scope_id;
    const capture_mod = @import("static_class_capture.zig");
    try capture_mod.pushContext(&transformer, parser.ast.getNode(binding).data.string_ref);
    const reference = (try capture_mod.makeThisReference(&transformer)).?;
    const capture = transformer.static_class_captures.get(@backingInt(binding)).?;
    try std.testing.expect(capture.symbol_id != null);
    try std.testing.expectEqual(capture.symbol_id, transformer.getSymbolIdAt(reference));
    try std.testing.expectEqual(capture.symbol_id, transformer.exact_output_ref_symbol_ids.get(@backingInt(reference)));
    try std.testing.expectEqual(analyzer.scopes.items[transformer.current_scope.toIndex()].parent, capture.frame.output_scope);
    try std.testing.expectEqual(transformer.getSymbolIdAt(binding), capture.frame.class_symbol_id);
    const editor = &transformer.semantic_editor.?;
    const recorded = (try editor.referenceForNode(reference)).?;
    try std.testing.expectEqual(capture.symbol_id.?, @backingInt(recorded.symbol_id));
    try std.testing.expectEqual(transformer.current_scope, recorded.scope_id);
    try std.testing.expect(recorded.flags.read and !recorded.flags.write);
    const declaration = (try capture_mod.takeDeclaration(&transformer, binding, parser.ast.getNode(owner).span)).?;
    try std.testing.expect(std.mem.indexOfScalar(u32, transformer.ast.preserve_lexical_declaration_indices.items, @backingInt(declaration)) != null);
    try std.testing.expect((try capture_mod.takeDeclaration(&transformer, binding, parser.ast.getNode(owner).span)) == null);
}

test "#4819 moved static eval guards builtin identity and inherited strictness" {
    const Case = struct { source: []const u8, rejects: bool };
    const cases = [_]Case{
        .{ .source = "function run(eval){class Box{static read=()=>eval('this');}return Box;}run(globalThis.eval);", .rejects = true },
        .{ .source = "class Box{static read=()=>eval('010');}", .rejects = true },
        .{ .source = "class Box{static read=function(){return eval('this');};}", .rejects = true },
        .{ .source = "class Box{static read=function(){return eval('arguments');};}", .rejects = true },
        .{ .source = "class Box{static read=function(){return eval('var local=7');};}", .rejects = true },
        .{ .source = "class Box{static read=function(){return eval('Box');};}", .rejects = true },
        .{ .source = "class Box{static read=()=>eval('1+2');}", .rejects = false },
        .{ .source = "function run(eval){class Box{static read=()=>eval('1+2');}return Box;}run(globalThis.eval);", .rejects = false },
        .{ .source = "function run(evaluate){class Box{static read=()=>evaluate('this');}return Box;}run(globalThis.eval);", .rejects = false },
        .{ .source = "class Box{static read=function(){const local=7;return eval('local');};}", .rejects = false },
    };
    for (cases) |fixture| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, fixture.source);
        var parser = Parser.init(allocator, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
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
        _ = try transformer.transform();
        try std.testing.expectEqual(fixture.rejects, transformer.used_unsupported_static_initializer_dynamic_scope);
    }
}

test "#4819 static class capture private post descriptor has exact live reference and lexical storage" {
    const source = "for (let i=0;i<3;i++) { class Box { static #value=i; static read=Box=>this.#value; } Box.read({}); }";
    try expectStaticCaptureIdentity(source, false, 1);
    try expectStaticCaptureIdentity(source, true, 1);
}

test "#4819 static class capture private brand uses exact nested class owner" {
    const source = "class Box { static #value=1; static make=()=>{ class Box { static #value=2; static read=Box=>this.#value; } return [this.#value,Box.read({})]; }; }";
    try expectStaticCaptureIdentity(source, false, 2);
    try expectStaticCaptureIdentity(source, true, 2);
}

test "#4819 static class capture private storage reserves its block ScopeId before reconciliation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "{ class Box { static #value=7; } }");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = true,
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
    const ast = @import("../parser/ast.zig");
    var owner: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) owner = @fromBackingInt(@intCast(raw));
    }
    const binding = parser.ast.readExtraNode(parser.ast.getNode(owner).data.extra, ast.ClassExtra.name);
    const body = parser.ast.readExtraNode(parser.ast.getNode(owner).data.extra, ast.ClassExtra.body);
    const self_id = analyzer.class_self_symbol_map.get(@backingInt(owner)).?;
    const class_scope = analyzer.symbols.items[self_id].scope_id;
    const output_scope = analyzer.scopes.items[class_scope.toIndex()].parent;
    transformer.current_scope = class_scope;
    transformer.current_class_name_node = binding;
    transformer.current_class_self_symbol_id = self_id;
    var new_body: ast.NodeIndex = .none;
    var pre: std.ArrayList(ast.NodeIndex) = .empty;
    var ctor: std.ArrayList(ast.NodeIndex) = .empty;
    var methods: std.ArrayList(Transformer.PrivateMethodMapping) = .empty;
    var fields: std.ArrayList(Transformer.PrivateFieldMapping) = .empty;
    var descriptors: std.ArrayList(ast.NodeIndex) = .empty;
    var orders: std.ArrayList(@import("es2022.zig").StaticDescriptorOrder) = .empty;
    try std.testing.expect(try @import("es2022.zig").ES2022(Transformer).lowerPrivateMembers(
        &transformer,
        body,
        &new_body,
        &pre,
        &ctor,
        &methods,
        &fields,
        true,
        true,
        false,
        "Box",
        binding,
        false,
        output_scope,
        &descriptors,
        &orders,
        false,
    ));
    try std.testing.expectEqual(@as(usize, 1), fields.items.len);
    const mapping = fields.items[0];
    const id = mapping.symbol_id.?;
    try std.testing.expectEqual(id, transformer.getSymbolIdAt(mapping.binding_node).?);
    const symbol = transformer.semantic_editor.?.symbols.items[id];
    try std.testing.expectEqual(output_scope, symbol.scope_id);
    try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_let, symbol.kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, transformer.semantic_editor.?.scopes.items[output_scope.toIndex()].kind);
    try std.testing.expectEqual(@as(usize, 1), pre.items.len);
    try std.testing.expectEqual(@as(usize, 1), descriptors.items.len);
    try std.testing.expectEqual(ast.VariableDeclarationKind.let, transformer.ast.variableDeclarationKind(transformer.ast.getNode(pre.items[0])));
}

test "#4819 strict initializer factory owns references before semantic reconciliation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "let outside=7; { class Box { static read=outside+this+(function named(value=outside){return Box;}); } }");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = true,
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
    const ast = @import("../parser/ast.zig");
    var owner: ast.NodeIndex = .none;
    var init: ast.NodeIndex = .none;
    var outside: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) owner = @fromBackingInt(@intCast(raw));
        if (node.tag == .property_definition) init = parser.ast.readExtraNode(node.data.extra, ast.PropertyExtra.init);
        if (outside.isNone() and node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "outside")) outside = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!owner.isNone() and !init.isNone() and !outside.isNone());
    const binding = parser.ast.readExtraNode(parser.ast.getNode(owner).data.extra, ast.ClassExtra.name);
    const class_self_id = analyzer.class_self_symbol_map.get(@backingInt(owner)).?;
    const class_scope = analyzer.symbols.items[class_self_id].scope_id;
    const output_scope = analyzer.scopes.items[class_scope.toIndex()].parent;
    transformer.current_scope = class_scope;
    transformer.current_class_name_node = binding;
    transformer.current_class_self_symbol_id = class_self_id;
    const context = try @import("es_helpers.zig").enterStaticInitContext(&transformer, parser.ast.getNode(binding).data.string_ref);
    defer @import("es_helpers.zig").leaveStaticInitContext(&transformer, context);
    const source_id = transformer.getSymbolIdAt(outside).?;
    const call = try @import("class_strict_context.zig").visitInitializer(&transformer, init, class_scope, output_scope);
    const factory = transformer.ast.readExtraNode(transformer.ast.getNode(call).data.extra, 0);
    const factory_scope = transformer.outputOwnedScope(factory).?;
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(output_scope, editor.scopes.items[factory_scope.toIndex()].parent);
    try std.testing.expect(editor.scopes.items[factory_scope.toIndex()].is_strict);
    const source_reference = (try editor.referenceForNode(outside)).?;
    try std.testing.expectEqual(source_id, @backingInt(source_reference.symbol_id));
    try std.testing.expectEqual(factory_scope, source_reference.scope_id);
    const capture = transformer.static_class_captures.get(@backingInt(binding)).?;
    try std.testing.expectEqual(output_scope, editor.symbols.items[capture.symbol_id.?].scope_id);
    var named_scope: @import("../semantic/scope.zig").ScopeId = .none;
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, call);
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .function_expression) continue;
        const name = transformer.ast.readExtraNode(node.data.extra, ast.FunctionExtra.name);
        if (name.isNone() or !std.mem.eql(u8, transformer.ast.identifierNameText(transformer.ast.getNode(name)), "named")) continue;
        named_scope = transformer.outputOwnedScope(@fromBackingInt(@intCast(raw))).?;
    }
    try std.testing.expect(!named_scope.isNone());
    var enclosing = named_scope;
    var steps: usize = 0;
    while (enclosing != factory_scope and !enclosing.isNone() and steps < editor.scopes.items.len) : (steps += 1) {
        try std.testing.expect(enclosing != class_scope and enclosing != output_scope);
        enclosing = editor.scopes.items[enclosing.toIndex()].parent;
    }
    try std.testing.expectEqual(factory_scope, enclosing);
    var generated_reads: usize = 0;
    var direct_reads: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != capture.symbol_id.? or reference.node_index.isNone()) continue;
        generated_reads += 1;
        if (reference.scope_id == factory_scope) direct_reads += 1 else try std.testing.expectEqual(named_scope, reference.scope_id);
        try std.testing.expect(reference.flags.read and !reference.flags.write);
        try std.testing.expectEqual(capture.symbol_id, transformer.exact_output_ref_symbol_ids.get(@backingInt(reference.node_index)));
    }
    try std.testing.expectEqual(@as(usize, 2), generated_reads);
    try std.testing.expectEqual(@as(usize, 1), direct_reads);
    const body = transformer.ast.readExtraNode(transformer.ast.getNode(factory).data.extra, ast.FunctionExtra.body);
    const list = transformer.ast.getNode(body).data.list;
    try std.testing.expectEqual(@as(u32, 2), list.len);
    try std.testing.expectEqual(ast.Node.Tag.directive, transformer.ast.getNode(@fromBackingInt(@intCast(transformer.ast.extra_data.items[list.start]))).tag);
}

test "#4819 strict initializer factory constructor name scope exists before reconciliation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const Box=class { constructor({value}={value:7}) { this.value=value; } };");
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const ast = @import("../parser/ast.zig");
    var owner: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) owner = @fromBackingInt(@intCast(raw));
    }
    const source_scope = transformer.outputOwnedScope(owner).?;
    const outer_scope = analyzer.scopes.items[source_scope.toIndex()].parent;
    var source_value_id: ?usize = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (symbol.kind == .parameter and std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) source_value_id = raw;
    }
    try std.testing.expect(source_value_id != null);
    transformer.current_scope = source_scope;
    const function = try @import("es2015_class.zig").ES2015Class(Transformer).lowerClassExpression(&transformer, owner, parser.ast.getNode(owner));
    try std.testing.expectEqual(ast.Node.Tag.function_expression, transformer.ast.getNode(function).tag);
    const binding = transformer.ast.readExtraNode(transformer.ast.getNode(function).data.extra, ast.FunctionExtra.name);
    const id = transformer.getSymbolIdAt(binding).?;
    const editor = &transformer.semantic_editor.?;
    const name_scope = editor.symbols.items[id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, editor.scopes.items[name_scope.toIndex()].kind);
    try std.testing.expectEqual(outer_scope, editor.scopes.items[name_scope.toIndex()].parent);
    try std.testing.expectEqual(@as(?usize, id), editor.scope_maps.items[name_scope.toIndex()].get(transformer.ast.identifierNameText(transformer.ast.getNode(binding))));
    const function_scope = transformer.outputOwnedScope(function).?;
    const parameters = transformer.ast.readExtraNode(transformer.ast.getNode(function).data.extra, ast.FunctionExtra.params);
    const parameter_scope = transformer.outputOwnedScope(parameters).?;
    try std.testing.expectEqual(parameter_scope, editor.scopes.items[function_scope.toIndex()].parent);
    var moved_parameter_bindings: usize = 0;
    const live = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, function);
    for (live) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.identifierNameText(node), "value")) continue;
        const value_id = transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))).?;
        try std.testing.expectEqual(source_value_id.?, value_id);
        try std.testing.expectEqual(function_scope, editor.symbols.items[value_id].scope_id);
        moved_parameter_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), moved_parameter_bindings);
    var enclosing = function_scope;
    var steps: usize = 0;
    while (enclosing != name_scope and !enclosing.isNone() and steps < editor.scopes.items.len) : (steps += 1) {
        try std.testing.expect(enclosing != source_scope and enclosing != outer_scope);
        enclosing = editor.scopes.items[enclosing.toIndex()].parent;
    }
    try std.testing.expectEqual(name_scope, enclosing);
    var reads: usize = 0;
    for (editor.references.items) |reference| {
        if (@backingInt(reference.symbol_id) != id or reference.node_index.isNone()) continue;
        reads += 1;
        try std.testing.expectEqual(function_scope, reference.scope_id);
        try std.testing.expect(reference.flags.read and !reference.flags.write);
    }
    try std.testing.expect(reads > 0);
}

test "#4819 constructor default closure keeps parameter identity before reconciliation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "let saved; const Box=class { constructor({value}={value:7},get=()=>value) { saved=get;var value=9;this.value=value; } };");
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
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const ast = @import("../parser/ast.zig");
    var owner: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) owner = @fromBackingInt(@intCast(raw));
    }
    const source_scope = transformer.outputOwnedScope(owner).?;
    const outer_scope = analyzer.scopes.items[source_scope.toIndex()].parent;
    _ = outer_scope;
    var parameter_id: ?usize = null;
    var body_var_id: ?usize = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (!std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) continue;
        if (symbol.kind == .parameter) parameter_id = raw;
        if (symbol.kind == .variable_var) body_var_id = raw;
    }
    try std.testing.expect(parameter_id != null and body_var_id != null and parameter_id.? != body_var_id.?);
    var default_read: ast.NodeIndex = .none;
    var default_scope: @import("../semantic/scope.zig").ScopeId = .none;
    for (analyzer.references.items) |reference| {
        if (reference.flags.read and @backingInt(reference.symbol_id) == parameter_id.?) {
            default_read = reference.node_index;
            default_scope = reference.scope_id;
        }
    }
    try std.testing.expect(!default_read.isNone());
    // Match the driver's collision-name planning, without running any output
    // reconciliation or final scope/reference walk.
    try transformer.buildBlockRenameMap();
    transformer.current_scope = source_scope;
    const function = try @import("es2015_class.zig").ES2015Class(Transformer).lowerClassExpression(&transformer, owner, parser.ast.getNode(owner));
    const function_scope = transformer.outputOwnedScope(function).?;
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(function_scope, editor.symbols.items[parameter_id.?].scope_id);
    try std.testing.expectEqual(function_scope, editor.symbols.items[body_var_id.?].scope_id);
    const live = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, function);
    var default_reads: usize = 0;
    for (live) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))) != @as(?u32, @intCast(parameter_id.?))) continue;
        try std.testing.expectEqual(@as(?u32, @backingInt(default_read)), transformer.reference_origin_map.get(raw));
        const read = (try editor.referenceForNode(@fromBackingInt(@intCast(raw)))).?;
        try std.testing.expectEqual(parameter_id.?, @backingInt(read.symbol_id));
        try std.testing.expectEqual(default_scope, read.scope_id);
        try std.testing.expect(read.flags.read and !read.flags.write);
        default_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), default_reads);
    try std.testing.expectEqual(function_scope, editor.scopes.items[default_scope.toIndex()].parent);
    var enclosing = default_scope;
    var steps: usize = 0;
    while (enclosing != function_scope and !enclosing.isNone() and steps < editor.scopes.items.len) : (steps += 1) {
        enclosing = editor.scopes.items[enclosing.toIndex()].parent;
    }
    try std.testing.expectEqual(function_scope, enclosing);
}
