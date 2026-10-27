const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const Options = @import("options.zig").TransformOptions;
const cells = @import("native_parameter_cells.zig");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");

fn checkCells(source: []const u8) !void {
    return checkCellsForTarget(source, .es2015);
}

fn checkCellsForTarget(source: []const u8, target: @import("compat.zig").ESTarget) !void {
    return checkCellsForFeatures(source, Options.compat.fromESTarget(target));
}

fn checkCellsForFeatures(source: []const u8, features: @import("compat.zig").UnsupportedFeatures) !void {
    return checkCellsForOptions(source, .{ .unsupported = features });
}

fn checkCellsForOptions(source: []const u8, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, options);
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
    var owner: ast.NodeIndex = .none;
    for (transformer.ast.nodes.items, 0..) |_, raw| {
        if (try cells.applies(&transformer, @fromBackingInt(@intCast(raw)))) {
            owner = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    try std.testing.expect(!owner.isNone());
    // Actual lexical cells require native block scoping; retaining native
    // defaults alone (for example Safari 10's compatibility set) is insufficient.
    transformer.options.unsupported.block_scoping = true;
    try std.testing.expect(!(try cells.applies(&transformer, owner)));
    transformer.options.unsupported.block_scoping = false;
    const scope = transformer.outputOwnedScope(owner).?;
    try transformer.buildBlockRenameMap();
    const before = transformer.ast.getNode(owner);
    const params = transformer.ast.functionParamsList(before);
    var original: std.ArrayList(struct { node: ast.NodeIndex, id: u32, parameter: usize, output_alias: []const u8 }) = .empty;
    var source_keys: std.ArrayList(struct { property: ast.NodeIndex, name: []const u8 }) = .empty;
    for (transformer.ast.extra_data.items[params.start .. params.start + params.len], 0..) |raw, parameter| {
        const nodes = try walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, @fromBackingInt(@intCast(raw)));
        for (nodes) |node_raw| {
            const property = transformer.ast.nodes.items[node_raw];
            if (property.tag != .binding_property) continue;
            const key = transformer.ast.getNode(property.data.binary.left);
            if (key.tag == .binding_identifier or key.tag == .identifier_reference)
                try source_keys.append(allocator, .{ .property = @fromBackingInt(@intCast(node_raw)), .name = transformer.ast.identifierNameText(key) });
        }
        var bindings = try walk.bindingIdentifiers(allocator, transformer.ast, @fromBackingInt(@intCast(raw)), .{});
        while (try bindings.next()) |binding| {
            const id = transformer.getSymbolIdAt(binding).?;
            const symbols = if (transformer.semantic_editor) |*editor| editor.symbols.items else transformer.symbols;
            try original.append(allocator, .{ .node = binding, .id = id, .parameter = parameter, .output_alias = symbols[id].synthetic_name });
        }
    }
    var default_function_scopes: std.ArrayList(@import("../semantic/scope.zig").ScopeId) = .empty;
    const parameter_owner = transformer.ast.readExtraNode(before.data.extra, if (before.tag == .arrow_function_expression) 0 else 1);
    const parameter_scope = transformer.outputOwnedScope(parameter_owner) orelse scope;
    for (transformer.ast.extra_data.items[params.start .. params.start + params.len]) |raw| {
        const nodes = try walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, @fromBackingInt(@intCast(raw)));
        for (nodes) |node_raw| {
            if (transformer.outputOwnedScope(@fromBackingInt(@intCast(node_raw)))) |nested| {
                if (analyzer.scopes.items[nested.toIndex()].parent == parameter_scope)
                    try default_function_scopes.append(allocator, nested);
            }
        }
    }
    const source_references = try allocator.dupe(@import("../semantic/symbol.zig").Reference, if (transformer.semantic_editor) |*editor| editor.references.items else analyzer.references.items);
    try cells.normalize(&transformer);
    // No visitNode, finishSemanticEdit, output walk or reanalysis has run.
    const editor = &transformer.semantic_editor.?;
    for (source_keys.items) |key| {
        const actual_key = transformer.ast.getNode(transformer.ast.getNode(key.property).data.binary.left);
        try std.testing.expectEqualStrings(key.name, transformer.ast.identifierNameText(actual_key));
    }
    for (source_references) |reference| {
        if (reference.flags.declare or reference.scope_id != parameter_scope) continue;
        const actual = (try editor.referenceForNode(reference.node_index)).?;
        try std.testing.expectEqual(scope, actual.scope_id);
        try std.testing.expectEqual(reference.symbol_id, actual.symbol_id);
    }
    for (default_function_scopes.items) |nested|
        try std.testing.expectEqual(scope, editor.scopes.items[nested.toIndex()].parent);
    var provenance = analyzer.node_scope_provenance.iterator();
    while (provenance.next()) |entry| {
        const moved = editor.node_scope_provenance.get(entry.key_ptr.*).?;
        try std.testing.expectEqual(if (entry.value_ptr.scope == parameter_scope) scope else entry.value_ptr.scope, moved.scope);
        try std.testing.expectEqual(entry.value_ptr.source_node, moved.source_node);
    }
    for (original.items) |binding| {
        try std.testing.expectEqual(binding.id, transformer.getSymbolIdAt(binding.node).?);
        const symbol = editor.symbols.items[binding.id];
        try std.testing.expectEqualStrings(binding.output_alias, symbol.synthetic_name);
        if (binding.output_alias.len > 0) {
            try std.testing.expectEqualStrings(binding.output_alias, transformer.ast.identifierNameText(transformer.ast.getNode(binding.node)));
            try std.testing.expectEqualStrings(binding.output_alias, transformer.ast.getText(transformer.ast.getNode(binding.node).span));
        }
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_let, symbol.kind);
        try std.testing.expectEqual(scope, symbol.scope_id);
        try std.testing.expect(symbol.decl_flags.block_scoped);
        try std.testing.expect(!symbol.decl_flags.is_parameter);
    }
    const after = transformer.ast.getNode(owner);
    const raw_params = transformer.ast.functionParamsList(after);
    var original_non_simple_formal = false;
    for (transformer.ast.extra_data.items[params.start .. params.start + params.len]) |raw| {
        const param = transformer.ast.nodes.items[raw];
        if (param.tag == .assignment_pattern or param.tag == .rest_element or param.tag == .spread_element or
            (param.tag == .formal_parameter and !transformer.ast.readExtraNode(param.data.extra, ast.FormalParameterExtra.default).isNone())) original_non_simple_formal = true;
    }
    try std.testing.expectEqual(params.len + @as(u32, if (original_non_simple_formal or editor.scopes.items[scope.toIndex()].is_strict) 0 else 1), raw_params.len);
    var raw_reads: usize = 0;
    for (transformer.ast.extra_data.items[raw_params.start .. raw_params.start + raw_params.len]) |raw| {
        const raw_param = transformer.ast.nodes.items[raw];
        if (raw_param.tag == .assignment_pattern) {
            const placeholder = transformer.ast.getNode(raw_param.data.binary.right);
            try std.testing.expectEqual(ast.Node.Tag.unary_expression, placeholder.tag);
            try std.testing.expectEqual(@as(u32, @backingInt(@import("../lexer/token.zig").Kind.kw_void)), transformer.ast.readExtra(placeholder.data.extra, 1));
        }
        var bindings = try walk.bindingIdentifiers(allocator, transformer.ast, @fromBackingInt(@intCast(raw)), .{});
        while (try bindings.next()) |binding| {
            const id = transformer.getSymbolIdAt(binding).?;
            try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, editor.symbols.items[id].kind);
            for (editor.references.items) |reference| {
                if (@backingInt(reference.symbol_id) != id or reference.flags.declare) continue;
                try std.testing.expectEqual(scope, reference.scope_id);
                try std.testing.expect(reference.flags.read);
                raw_reads += 1;
            }
        }
    }
    try std.testing.expect(raw_reads >= params.len);
    try std.testing.expectEqual(params.len, transformer.ast.preserve_lexical_declaration_indices.items.len);
    const body = transformer.ast.readExtraNode(after.data.extra, if (after.tag == .arrow_function_expression) 1 else 2);
    const list = transformer.ast.getNode(body).data.list;
    for (0..params.len) |i| {
        const statement: ast.NodeIndex = @fromBackingInt(@intCast(transformer.ast.extra_data.items[list.start + i]));
        try std.testing.expectEqual(@backingInt(statement), transformer.ast.preserve_lexical_declaration_indices.items[i]);
        try std.testing.expectEqual(ast.VariableDeclarationKind.let, transformer.ast.variableDeclarationKind(transformer.ast.getNode(statement)));
        const declaration = transformer.ast.getNode(statement);
        const declarations = transformer.ast.readExtra(declaration.data.extra, 1);
        const declarator = transformer.ast.getNode(transformer.ast.readExtraNode(declarations, 0));
        const pattern = transformer.ast.readExtraNode(declarator.data.extra, 0);
        var bindings = try walk.bindingIdentifiers(allocator, transformer.ast, pattern, .{});
        var matched: usize = 0;
        while (try bindings.next()) |binding| {
            var found = false;
            for (original.items) |source_binding| {
                if (source_binding.parameter != i or source_binding.node != binding) continue;
                try std.testing.expectEqual(source_binding.id, transformer.getSymbolIdAt(binding).?);
                found = true;
                break;
            }
            try std.testing.expect(found);
            matched += 1;
        }
        var expected: usize = 0;
        for (original.items) |source_binding| {
            if (source_binding.parameter == i) expected += 1;
        }
        try std.testing.expectEqual(expected, matched);
    }
}

test "native parameter cells exist with exact identities before output finalization" {
    try checkCells("function run(get=()=>value,{...value}={n:7}){return get;}");
    try checkCells("const run=(get=()=>value,{...value}={n:7})=>get;");
    try checkCells("function run(first=(()=>value)(),{...value}={n:7}){return first;}");
    try checkCells("function run(first=(()=>{value=9})(),{...value}={n:7}){return first;}");
    try checkCells("function run(first,get=()=>value,{...value}={n:7},after=value){return after;}");
    try checkCells("function run(get=function(){return value},{...value}={n:7}){return get;}");
    try checkCells("const run=(get=()=>value,{...value}={n:7},...tail)=>[get,tail];");
    try checkCells("function run(get=()=>value,{n,...value}={n:7,m:8}){return get;}");
    try checkCells("function run(get=()=>value,{...value}){return get;}");
    try checkCells("function run(get=()=>value,{...value}={n:7},after=()=>value){return after;}");
    try checkCells("function run(before=import('dep'),{...value}={n:7}){return value;}");
    try checkCells("function run(before=()=>import('dep'),{...value}={n:7}){return value;}");
    try checkCells("function run(get,{...value}){return value;}");
    try checkCells("const run=({...value})=>value;");
    try checkCells("function run({a,...rest},value=a){var a=4;return[value,a];}");
    try checkCells("function run(get=()=>value,{...value}={n:7}){var value={n:9};return[get,value];}");
    try checkCells("function run({a=7,...rest}={},get=()=>a){var a=9;return[get,a];}");
}

fn checkNativeParameterArrowScope(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    var outer_arrow: ?ast.NodeIndex = null;
    var capture_arrow: ?ast.NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .arrow_function_expression) continue;
        const params = parser.ast.functionParamsList(node);
        if (params.len == 2) {
            try std.testing.expect(outer_arrow == null);
            outer_arrow = @fromBackingInt(@intCast(raw));
        } else if (params.len == 0) {
            try std.testing.expect(capture_arrow == null);
            capture_arrow = @fromBackingInt(@intCast(raw));
        }
    }
    const outer = outer_arrow orelse return error.MissingOuterArrow;
    const capture = capture_arrow orelse return error.MissingDefaultArrow;
    const outer_params = parser.ast.functionParamsList(parser.ast.getNode(outer));
    const rest_default: ast.NodeIndex = @fromBackingInt(@intCast(parser.ast.extra_data.items[outer_params.start + 1]));
    try std.testing.expectEqual(ast.Node.Tag.assignment_pattern, parser.ast.getNode(rest_default).tag);
    const rest_pattern = parser.ast.getNode(rest_default).data.binary.left;
    var bindings = try walk.bindingIdentifiers(allocator, &parser.ast, rest_pattern, .{});
    defer bindings.deinit();
    var value_binding: ?ast.NodeIndex = null;
    while (try bindings.next()) |binding| {
        if (!std.mem.eql(u8, parser.ast.identifierNameText(parser.ast.getNode(binding)), "value")) continue;
        try std.testing.expect(value_binding == null);
        value_binding = binding;
    }
    const binding = value_binding orelse return error.MissingRestBinding;
    const value_id = analyzer.symbol_ids.items[@backingInt(binding)] orelse return error.MissingRestBindingSymbol;

    var capture_reference_nodes: std.ArrayList(ast.NodeIndex) = .empty;
    const capture_nodes = try walk.collectReachableNodeIndicesFrom(allocator, &parser.ast, capture);
    defer allocator.free(capture_nodes);
    for (capture_nodes) |raw| {
        const node = parser.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.identifierNameText(node), "value")) continue;
        try capture_reference_nodes.append(allocator, @fromBackingInt(@intCast(raw)));
    }
    try std.testing.expect(capture_reference_nodes.items.len > 0);
    const source_capture_scope: u32 = @intCast(analyzer.scope_owner_map.get(@backingInt(capture)) orelse return error.MissingSourceCaptureScope);
    for (capture_reference_nodes.items) |capture_ref_node| {
        var source_reference_found = false;
        for (analyzer.references.items) |reference| {
            if (reference.node_index != capture_ref_node) continue;
            try std.testing.expectEqual(value_id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(source_capture_scope, @backingInt(reference.scope_id));
            source_reference_found = true;
        }
        try std.testing.expect(source_reference_found);
    }

    const parameter_node = parser.ast.readExtraNode(parser.ast.getNode(outer).data.extra, 0);
    const parameter_scope: u32 = @intCast(analyzer.scope_owner_map.get(@backingInt(parameter_node)) orelse return error.MissingSourceParameterScope);
    const expected_body_scope: u32 = @intCast(analyzer.scope_owner_map.get(@backingInt(outer)) orelse return error.MissingSourceBodyScope);
    try std.testing.expectEqual(parameter_scope, @backingInt(analyzer.scopes.items[source_capture_scope].parent));
    try std.testing.expect(expected_body_scope != parameter_scope);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = Options.compat.fromESTarget(.es2015),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.helper_scope_map = analyzer.helper_scope_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;

    const output_root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const output_scope = @backingInt(edited.symbols.items[value_id].scope_id);
    const capture_scope = source_capture_scope;
    // The lowered destructuring binding is initialized in the function body;
    // default closures move with that initialization and must retain their exact
    // scope edge to the output body binding.
    try std.testing.expectEqual(expected_body_scope, output_scope);
    try std.testing.expectEqual(output_scope, @backingInt(edited.scopes[capture_scope].parent));
    try std.testing.expectEqual(@as(?u32, value_id), edited.symbol_ids[@backingInt(binding)]);

    for (capture_reference_nodes.items) |capture_ref_node| {
        var capture_reference_count: usize = 0;
        for (edited.references) |reference| {
            if (reference.node_index != capture_ref_node) continue;
            try std.testing.expectEqual(value_id, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(capture_scope, @backingInt(reference.scope_id));
            try std.testing.expectEqual(@as(?u32, value_id), edited.symbol_ids[@backingInt(reference.node_index)]);
            capture_reference_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), capture_reference_count);
    }

    for (capture_reference_nodes.items) |capture_ref_node| {
        var reference_scope: @import("../semantic/scope.zig").ScopeId = undefined;
        for (edited.references) |reference| {
            if (reference.node_index == capture_ref_node) {
                reference_scope = reference.scope_id;
                break;
            }
        }
        var resolves_to_cell = false;
        var remaining = edited.scopes.len;
        while (!reference_scope.isNone() and reference_scope.toIndex() < edited.scopes.len and remaining > 0) : (remaining -= 1) {
            if (@backingInt(reference_scope) == output_scope) {
                resolves_to_cell = true;
                break;
            }
            reference_scope = edited.scopes[reference_scope.toIndex()].parent;
        }
        try std.testing.expect(resolves_to_cell);
    }

    const exact = try @import("symbol_coverage.zig").checkExactWithNamespaceMetadataAndDeclarationAnchors(
        allocator,
        transformer.ast,
        output_root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        edited.scope_maps,
        &edited.scope_owner_map,
        edited.references,
        transformer.helper_ref_nodes.items,
        &edited.helper_scope_map,
        &analyzer.unresolved_reference_nodes,
        &transformer.explicit_global_reference_nodes,
        &transformer.reference_origin_map,
        &analyzer.namespace_member_owners,
        &analyzer.namespace_declaration_owners,
        analyzer.scopes.items.len,
    );
    try std.testing.expect(exact.isClean());
}

test "native parameter arrow references keep their exact output scopes and binding" {
    const cases = [_][]const u8{
        "const run=(capture=()=>value,{...value}={n:7,ignored:9})=>[capture(),value];",
        "const value=99;const run=(capture=()=>value,{...value}={n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>value.n,{...value}={n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>value[\"n\"],{...value}={n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>({captured:value}),{...value}={n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>{let marker=1;return value;},{...value}={n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>{value.n++;return value;},{...value}={n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>value,{first,...value}={first:1,n:7,ignored:9})=>[capture(),value];",
        "const run=(capture=()=>value,{nested:{...value}}={nested:{n:7,ignored:9}})=>[capture(),value];",
        "const run=(capture=()=>value,{nested:{...value}={n:7,ignored:9}}={nested:undefined})=>[capture(),value];",
        "const run=(capture=()=>value,[{...value}]=[{n:7,ignored:9}])=>[capture(),value];",
        "const run=(capture=()=>value,[...{...value}]=[{n:7,ignored:9}])=>[capture(),value];",
        "const run=(capture=()=>value,{outer:{inner:{...value}}}={outer:{inner:{n:7,ignored:9}}})=>[capture(),value];",
        "const run=(capture=()=>value,{nested:[{...value}]}={nested:[{n:7,ignored:9}]})=>[capture(),value];",
        "const run=(capture=()=>value,{...value}={n:7,ignored:9})=>{var other=value;return[capture(),other,value];};",
    };
    for (cases) |source| try checkNativeParameterArrowScope(source);
}

test "native class parameter cells exist before class visitation" {
    try checkCells("class Box{constructor(get=()=>value,{...value}={n:7}){this.get=get;}}");
    try checkCells("class Box{method(get=()=>value,{...value}={n:7}){return get;}}");
    try checkCells("class Box{static method(get=()=>value,{...value}={n:7}){return get;}}");
    try checkCells("class Base{}class Box extends Base{constructor(get=()=>[value,this,new.target],{...value}={n:7}){super();this.get=get;}}");
    try checkCells("class Box{constructor({a,...rest},get=()=>a){var a=9;this.get=get;}}");
    try checkCells("class Box{method(before=(()=>value)(),{...value}={n:7}){return before;}}");
    try checkCells("class Box{static method(before=(()=>{value=9})(),{...value}={n:7}){return before;}}");
    try checkCells("class Box{method(before=import('dep'),{...value}={n:7}){return before;}}");
    try checkCells("class Box{constructor(before=()=>import('dep'),{...value}={n:7}){this.get=before;}}");
    try checkCells("class Box{set value({...value}){this.saved=value;}}");
    try checkCells("class Box{static set value({...value}){this.saved=value;}}");
    try checkCells("class Box{static set value({...value}){this.saved=[value.n,Object.getOwnPropertyDescriptor(Box,'value').set.length];}}");
    for ([_]@import("compat.zig").ESTarget{ .es2015, .es2018 }) |target| {
        try checkCellsForTarget("class Box{field=7;constructor(value=this.field){this.saved=value;}}", target);
        try checkCellsForTarget("class Box{#field=7;constructor(value=this.#field){this.saved=value;}}", target);
        try checkCellsForTarget("class Box{#read(){return 7}constructor(value=this.#read()){this.saved=value;}}", target);
        try checkCellsForTarget("class Box{field=7;constructor(get=()=>value,{...value}={n:7}){this.saved=get;}}", target);
    }
}

test "native parameter cell body publication survives actual extra-data relocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "class Box{static set value(raw){this.saved=[raw.n,Box.name]}}");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    var body_slot: u32 = undefined;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag == .method_definition) {
            body_slot = node.data.extra + ast.MethodExtra.body;
            break;
        }
    } else return error.TestUnexpectedResult;
    const body: ast.NodeIndex = @fromBackingInt(transformer.ast.extra_data.items[body_slot]);
    const original_list = transformer.ast.getNode(body).data.list;
    const original_statement = transformer.ast.extra_data.items[original_list.start];
    const number = try @import("es_helpers.zig").makeNumericLiteral(&transformer, 7);
    const initializer = try @import("es_helpers.zig").makeExprStmt(&transformer, number, transformer.ast.getNode(body).span);
    // Force the precise allocation boundary that lost the initializer when
    // the destination pointer was evaluated before constructing the new body.
    var exact = try std.ArrayList(u32).initCapacity(allocator, transformer.ast.extra_data.items.len);
    exact.appendSliceAssumeCapacity(transformer.ast.extra_data.items);
    transformer.ast.extra_data = exact;
    _ = try allocator.alloc(u8, 128); // prevent arena in-place growth
    const before = transformer.ast.extra_data.items.ptr;
    try cells.publishBody(&transformer, body_slot, body, &.{initializer});
    try std.testing.expect(before != transformer.ast.extra_data.items.ptr);
    const published: ast.NodeIndex = @fromBackingInt(transformer.ast.extra_data.items[body_slot]);
    const statements = transformer.ast.getNode(published).data.list;
    try std.testing.expectEqual(original_list.len + 1, statements.len);
    try std.testing.expectEqual(@backingInt(initializer), transformer.ast.extra_data.items[statements.start]);
    try std.testing.expectEqual(original_statement, transformer.ast.extra_data.items[statements.start + 1]);
}

fn checkClassSelection(source: []const u8, target: @import("compat.zig").ESTarget, metadata: bool, expected: usize) !void {
    return checkClassSelectionWithMode(source, target, metadata, expected, true);
}

fn checkClassSelectionWithMode(source: []const u8, target: @import("compat.zig").ESTarget, metadata: bool, expected: usize, is_ts: bool) !void {
    return checkClassSelectionWithOptions(source, .{ .unsupported = Options.compat.fromESTarget(target), .emit_decorator_metadata = metadata }, expected, is_ts);
}

fn checkClassSelectionWithOptions(source: []const u8, options: Options, expected: usize, is_ts: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    if (is_ts) parser.configureForBundlerKind(true, false) else parser.configureForBundler(".cjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_ts = is_ts;
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, options);
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    var selected: usize = 0;
    for (transformer.ast.nodes.items, 0..) |_, raw| {
        if (try cells.applies(&transformer, @fromBackingInt(@intCast(raw)))) selected += 1;
    }
    try std.testing.expectEqual(expected, selected);
}

test "native class parameter selection uses actual constructor and instance owner" {
    try checkClassSelection("class Box{field=7;constructor(value=this.field){}}", .es2018, false, 1);
    try checkClassSelection("class Box{field=7;constructor(value=this.field){}}", .es2022, false, 0);
    try checkClassSelection("class Box{static field=7;constructor(value=1){}}", .es2018, false, 0);
    try checkClassSelection("class Box{field=7;static constructor(value=1){}}", .es2018, false, 0);
    try checkClassSelection("class Box{#field=7;['constructor'](value=2){return value}}", .es2018, false, 0);
    try checkClassSelection("class Box{declare field:number;constructor(value=1){}}", .es2018, false, 0);
    try checkClassSelection("abstract class Box{abstract field:number;constructor(value=1){}}", .es2018, false, 0);
    try checkClassSelection("class Box{field={set value({...value}){this.saved=value}}}", .es2015, false, 0);
    try checkClassSelection("const object={set value({...value}){this.saved=value}};", .es2015, false, 0);
    try checkClassSelection("class Box{field=7;method(){return class Box{constructor(value=1){}}}}", .es2018, false, 0);
    try checkClassSelection("class Box{method(){return class Box{field=7;constructor(value=this.field){}}}}", .es2018, false, 1);
    try checkClassSelection("@mark class Box{field=7;constructor(value=this.field){}}", .es2018, true, 0);
    try checkClassSelection("@mark class Other{}class Box{field=7;constructor(value=this.field){}}", .es2018, true, 1);
    try checkClassSelection("class Box{field=7;constructor(public value=1){}}", .es2018, false, 0);
    try checkClassSelection("declare class Box{constructor({a,...rest}:{a:number,b:number});}", .es2015, false, 0);
    try checkClassSelection("class Box{field=eval('1+2');constructor(value=1){}}", .es2018, false, 1);
    try checkClassSelection("class Box{field=eval('this');constructor(value=1){}}", .es2018, false, 1);
    try checkClassSelection("class Box{field=eval('outside');constructor(outside=1){}}", .es2018, false, 0);
    try checkClassSelection("class Box{field=eval('new.target');constructor(value=1){}}", .es2018, false, 0);
    try checkClassSelection("class Box{method(get=()=>eval('value'),{...value}={n:7}){}}", .es2015, false, 0);
    try checkClassSelection("class Box{method(get=()=>value,{...value}={n:7}){eval('value')}}", .es2015, false, 0);
    try checkClassSelectionWithMode("function outer(eval){return class Box{method(get=()=>eval('value'),{...value}={n:7}){}}}", .es2015, false, 0, false);
    try checkClassSelection("class Box{accessor field=7;constructor(value=this.field){}}", .es2022, false, 0);
    try checkClassSelection("class Box{accessor field=7;constructor(value=this.field){}}", .es2018, false, 1);
    try checkClassSelection("class Box{#field=7;constr\\u0075ctor(value=this.#field){}}", .es2018, false, 1);
}

test "constructor StringValue and class-member role survive exact scope copying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "class Box{constr\\u0075ctor(){}static constructor(){}}const object={constructor(){}};");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    var constructor: ast.NodeIndex = .none;
    var rejected: usize = 0;
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .method_definition) continue;
        const owner: ast.NodeIndex = @fromBackingInt(@intCast(raw));
        if (@import("es_helpers.zig").isClassConstructorMethod(&transformer, owner, node)) {
            try std.testing.expect(constructor.isNone());
            constructor = owner;
        } else rejected += 1;
    }
    try std.testing.expect(!constructor.isNone());
    try std.testing.expectEqual(@as(usize, 2), rejected);
    const copy = try transformer.ast.addNode(transformer.ast.getNode(constructor));
    try transformer.remapCopiedScopeOwner(constructor, copy);
    try std.testing.expect(@import("es_helpers.zig").isClassConstructorMethod(&transformer, copy, transformer.ast.getNode(copy)));
}

test "native class parameter cells honor common private lowering plan" {
    try checkCellsForFeatures("class Box{#field=7;constructor(value=this.#field){this.saved=value}}", .{ .class_private_method = true });
    try checkCellsForFeatures("class Box{#read(){return 7}constructor(value=this.#read()){this.saved=value}}", .{ .class_private_field = true });
    try checkCellsForFeatures("const outside=99;class Box{static #field=7;field=outside;constructor(outside=1){this.saved=outside}}", .{ .class_private_method = true });
    try checkCellsForFeatures("class Box{accessor field=7;constructor(value=this.field){this.saved=value}}", .{ .class_private_method = true, .decorator_auto_accessor = true });
}

test "common private lowering plan reaches both native class producers" {
    for ([_]bool{ false, true }) |field_unsupported| {
        for (0..4) |style| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            const members = "{static #extra=3;#field=7;#read(){return this.#field}constructor(value=this.#read()){this.saved=value}read(other=this){other.#field++;return other?.#field}}";
            const source = if (style == 3) "const Box=class" ++ members else "class Box" ++ members;
            var scanner = try Scanner.init(allocator, source);
            var parser = Parser.init(allocator, &scanner);
            _ = try parser.parse();
            var analyzer = Analyzer.init(allocator, &parser.ast);
            try analyzer.analyze();
            var transformer = try Transformer.init(allocator, &parser.ast, .{
                .unsupported = .{ .class_private_field = field_unsupported, .class_private_method = !field_unsupported },
                .use_define_for_class_fields = style != 1,
                .experimental_decorators = style == 2,
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
            const root = try transformer.transform();
            const live = try walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
            for (live) |raw| {
                const node = transformer.ast.nodes.items[raw];
                if (node.tag != .update_expression) continue;
                const operand = transformer.ast.getNode(transformer.ast.readExtraNode(node.data.extra, 0));
                // JavaScript permits a storage target, never a getter call,
                // as the operand of ++ after private-field replacement.
                try std.testing.expect(operand.tag != .call_expression);
            }
            const editor = &transformer.semantic_editor.?;
            var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(allocator, transformer.ast, .{
                .assert_no_raw_private_syntax = true,
                .semantic_symbol_ids = transformer.symbol_ids.items,
                .semantic_symbols = editor.symbols.items,
                .semantic_scope_maps = editor.scope_maps.items,
                .generated_iife_scope_owner_map = &editor.scope_owner_map,
            });
            const code = try codegen.generate(root);
            try std.testing.expect(std.mem.indexOf(u8, code, "WeakMap") != null);
            try std.testing.expect(std.mem.indexOf(u8, code, "WeakSet") != null);
            var output_scanner = try Scanner.init(allocator, code);
            var output_parser = Parser.init(allocator, &output_scanner);
            _ = try output_parser.parse();
            try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
        }
    }
}

test "native private initializer mixed assignment parameter cells exist before class visitation" {
    const options: Options = .{ .use_define_for_class_fields = false };
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(value=this.#field){this.saved=value}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;#read(){return this.#field}constructor(value=this.#read()){this.saved=value}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;get #read(){return this.#field}constructor(value=this.#read){this.saved=value}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(get=()=>value,value=this.#field){this.get=get}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(first=(()=>value)(),value=this.#field){}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(first=(()=>{value=9})(),value=this.#field){}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(get=()=>value,value=this.#field){var value=9;this.get=get}}", options);
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(value=this.#field){this.saved=value}}", .{ .use_define_for_class_fields = false, .experimental_decorators = true });
    // Transformer.init normalizes legacy decorators to assign semantics even
    // when the caller requested define semantics. Classify the actual options.
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(value=this.#field){this.saved=value}}", .{ .experimental_decorators = true });
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(value=this.#field){this.saved=value}}", .{ .unsupported = .{ .class_field = true } });
    try checkClassSelectionWithOptions("class Box{#field=7;static publicField=1;constructor(value=this.#field){this.saved=value}}", .{ .unsupported = .{ .class_field = true } }, 0, false);
    try checkCellsForOptions("class Box{#field=7;publicField=1;constructor(value=this.#field){this.saved=value}}", .{ .unsupported = .{ .class_field = true }, .experimental_decorators = true });
    try checkCellsForOptions("class Box{accessor field=7;constructor(value=this.field){this.saved=value}}", .{ .unsupported = .{ .decorator_auto_accessor = true }, .use_define_for_class_fields = false });
}

test "native private initializer parameter cells require actual instance movement" {
    const options: Options = .{ .use_define_for_class_fields = false };
    try checkClassSelectionWithOptions("class Box{#field=7;constructor(value=this.#field){}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{#field=7;constructor(get=()=>value,value=this.#field){}}", .{ .experimental_decorators = true }, 0, false);
    try checkClassSelectionWithOptions("class Box{#field;constructor(value=this.#field){}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{static #field=7;constructor(value=1){}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{#read(){return 7}constructor(value=this.#read()){}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{#field=7;static constructor(value=1){}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{#field=7;['constructor'](value=1){}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{#field=7;constructor(value=this.#field){}}", .{}, 0, false);

    try checkClassSelectionWithOptions("class Box{#field=7;constructor(value=this.#field){}}", .{ .unsupported = .{ .class_field = true } }, 0, false);
    try checkClassSelectionWithOptions("class Box{#field=7;constructor(value=this.#field){eval('value')}}", options, 0, false);
    try checkClassSelectionWithOptions("class Box{#field=eval('outside');constructor(value=this.#field){}}", options, 0, false);
}
