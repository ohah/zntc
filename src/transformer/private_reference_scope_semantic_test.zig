const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("options.zig").TransformOptions;
const ast = @import("../parser/ast.zig");

fn expectPrivateReferencesAtCreation(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    var owner: ast.NodeIndex = .none;
    var start: u32 = std.math.maxInt(u32);
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration and node.span.start < start) {
            owner = @fromBackingInt(@intCast(raw));
            start = node.span.start;
        }
    }
    try std.testing.expect(!owner.isNone());
    const class = parser.ast.getNode(owner);
    const binding = parser.ast.readExtraNode(class.data.extra, ast.ClassExtra.name);
    const body = parser.ast.readExtraNode(class.data.extra, ast.ClassExtra.body);
    const super = parser.ast.readExtraNode(class.data.extra, ast.ClassExtra.super);
    const self_id = analyzer.class_self_symbol_map.get(@backingInt(owner)).?;
    const class_scope = analyzer.symbols.items[self_id].scope_id;
    const output_scope = analyzer.scopes.items[class_scope.toIndex()].parent;
    var source_ctor_scope: ?@import("../semantic/scope.zig").ScopeId = null;
    var original_members = parser.ast.iterateExtraList(parser.ast.getNode(body).data.list);
    while (original_members.next()) |member| {
        const node = parser.ast.getNode(member);
        if (node.tag == .method_definition and
            parser.ast.readExtra(node.data.extra, ast.MethodExtra.flags) & ast.MethodFlags.is_static == 0 and
            @import("es_helpers.zig").isConstructorKey(&transformer, parser.ast.readExtraNode(node.data.extra, ast.MethodExtra.key)))
            source_ctor_scope = transformer.outputOwnedScope(member);
    }
    transformer.current_scope = class_scope;
    transformer.current_class_name_node = binding;
    transformer.current_class_self_symbol_id = self_id;
    try transformer.buildBlockRenameMap();
    // Prove the scope choice before private descriptor references are created;
    // a later method-body relocation must not hide a wrong static owner.
    if (source_ctor_scope) |original|
        try std.testing.expectEqual(original, try @import("es2022.zig").ES2022(Transformer).reservePrivateConstructorScope(&transformer, body, &.{}, &.{}));
    var output_body: ast.NodeIndex = .none;
    var pre: std.ArrayList(ast.NodeIndex) = .empty;
    var ctor: std.ArrayList(ast.NodeIndex) = .empty;
    var methods: std.ArrayList(Transformer.PrivateMethodMapping) = .empty;
    var fields: std.ArrayList(Transformer.PrivateFieldMapping) = .empty;
    var descriptors: std.ArrayList(ast.NodeIndex) = .empty;
    var orders: std.ArrayList(@import("es2022.zig").StaticDescriptorOrder) = .empty;
    try std.testing.expect(try @import("es2022.zig").ES2022(Transformer).lowerPrivateMembers(
        &transformer,
        body,
        &output_body,
        &pre,
        &ctor,
        &methods,
        &fields,
        true,
        true,
        !super.isNone(),
        "Box",
        binding,
        false,
        output_scope,
        &descriptors,
        &orders,
        false,
    ));
    // This assertion runs before class-tree tracking or finishSemanticEdit.
    // Exact generated private references must already have Reference rows.
    const editor = &transformer.semantic_editor.?;
    if (ctor.items.len > 0) {
        var found = false;
        var members = transformer.ast.iterateExtraList(transformer.ast.getNode(output_body).data.list);
        while (members.next()) |member| {
            const node = transformer.ast.getNode(member);
            if (node.tag != .method_definition or
                transformer.ast.readExtra(node.data.extra, ast.MethodExtra.flags) & ast.MethodFlags.is_static != 0 or
                !@import("es_helpers.zig").isConstructorKey(&transformer, transformer.ast.readExtraNode(node.data.extra, ast.MethodExtra.key))) continue;
            const scope = transformer.outputOwnedScope(member);
            try std.testing.expect(scope != null);
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, editor.scopes.items[scope.?.toIndex()].kind);
            if (source_ctor_scope) |original| try std.testing.expectEqual(original, scope.?) else try std.testing.expectEqual(class_scope, editor.scopes.items[scope.?.toIndex()].parent);
            found = true;
        }
        try std.testing.expect(found);
    }
    for (transformer.pending_exact_symbol_refs.items) |pending| {
        const reference = try editor.referenceForNode(pending.node);
        try std.testing.expect(reference != null);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_exact_symbol_refs.items.len);
    var private_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (fields.items) |field| try private_ids.put(allocator, field.symbol_id.?, {});
    for (methods.items) |method| {
        try private_ids.put(allocator, method.weakset_symbol_id.?, {});
        try private_ids.put(allocator, method.func_symbol_id.?, {});
        if (method.func_outer_symbol_id) |id| try private_ids.put(allocator, id, {});
    }
    const private_mapping_ids = try private_ids.clone(allocator);
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const Work = struct { node: ast.NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    try stack.append(allocator, .{ .node = output_body, .scope = class_scope });
    for (pre.items) |node| try stack.append(allocator, .{ .node = node, .scope = output_scope });
    for (descriptors.items) |node| try stack.append(allocator, .{ .node = node, .scope = output_scope });
    // Include computed-key temps, generated capture parameters, and implicit
    // constructor parameters alongside the private mapping identities.
    var bindings: std.ArrayList(Work) = .empty;
    try bindings.appendSlice(allocator, stack.items);
    while (bindings.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = transformer.ast.getNode(work.node);
        if (node.tag == .binding_identifier and @backingInt(work.node) >= transformer.parser_node_count) {
            if (transformer.getSymbolIdAt(work.node)) |id| try private_ids.put(allocator, id, {});
        }
        var children = @import("../parser/ast_walk.zig").children(transformer.ast, node);
        while (children.next()) |child| try bindings.append(allocator, .{ .node = child, .scope = work.scope });
    }
    var references: usize = 0;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        const node = transformer.ast.getNode(work.node);
        const scope = transformer.outputOwnedScope(work.node) orelse work.scope;
        if ((node.tag == .identifier_reference or node.tag == .assignment_target_identifier) and raw >= transformer.parser_node_count) {
            if (transformer.getSymbolIdAt(work.node)) |id| {
                if (private_ids.contains(id)) {
                    const reference = (try editor.referenceForNode(work.node)).?;
                    try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                    try std.testing.expectEqual(scope, reference.scope_id);
                    if (private_mapping_ids.contains(id)) {
                        try std.testing.expectEqual(id, transformer.exact_output_ref_symbol_ids.get(raw).?);
                        try std.testing.expectEqual(node.tag == .identifier_reference, reference.flags.read);
                        try std.testing.expectEqual(node.tag == .assignment_target_identifier, reference.flags.write);
                    } else if (transformer.reference_origin_map.get(raw)) |origin| {
                        for (analyzer.references.items) |original| {
                            if (@backingInt(original.node_index) == origin)
                                try std.testing.expectEqual(original.flags, reference.flags);
                        }
                    }
                    references += 1;
                }
            }
        }
        var children = @import("../parser/ast_walk.zig").children(transformer.ast, node);
        while (children.next()) |child| try stack.append(allocator, .{ .node = child, .scope = scope });
    }
    try std.testing.expect(references > 0);
}

test "#4819 private reference creation static descriptor" {
    try expectPrivateReferencesAtCreation("class Box{static #value=1;static read(){return this.#value;}}");
}
test "#4819 private reference creation nested same-name arrow" {
    try expectPrivateReferencesAtCreation("class Box{static #value=1;static read=()=>{class Box{static #value=2;static read(){return this.#value;}}return Box.read();};}");
}
test "#4819 private reference creation implicit base constructor" {
    try expectPrivateReferencesAtCreation("class Box{#value=1;read(){return this.#value;}}");
}
test "#4819 private reference creation implicit derived constructor" {
    try expectPrivateReferencesAtCreation("class Box extends Base{#value=1;read(){return this.#value;}}");
}
test "#4819 private reference creation existing non-simple constructor" {
    try expectPrivateReferencesAtCreation("class Box{constructor(value=1){this.value=value;}#value=2;read(){return this.#value;}}");
}
test "#4819 private reference creation static constructor name does not own instance initialization" {
    try expectPrivateReferencesAtCreation("class Box{#value=7;static constructor(value=2){return value}read(){return this.#value}}");
    try expectPrivateReferencesAtCreation("class Box{#value=7;constructor(value=1){this.value=value}static constructor(value=2){return value}}");
    try expectPrivateReferencesAtCreation("class Box{#value=7;static constructor(value=2){return value}constructor(value=1){this.value=value}}");
}
test "#4819 private reference creation static method descriptor" {
    try expectPrivateReferencesAtCreation("class Box{static #read(){return 1;}static run(){return this.#read();}}");
}
test "#4819 private reference creation instance method initialization" {
    try expectPrivateReferencesAtCreation("class Box{#read(){return 1;}run(){return this.#read();}}");
}
test "#4819 private reference creation static getter descriptor" {
    try expectPrivateReferencesAtCreation("class Box{static get #value(){return 1;}static run(){return this.#value;}}");
}
test "#4819 private reference creation accessor shared brand" {
    try expectPrivateReferencesAtCreation("class Box{get #value(){return 1;}set #value(value){this.seen=value;}run(){this.#value=2;return this.#value;}}");
}
test "#4819 private reference creation computed field and rest constructor" {
    try expectPrivateReferencesAtCreation("const _value=9;class Box{#value=1;['arrow']=()=>this.#value;constructor(...args){this.args=args;}}");
}

test "#4819 private reference creation native method default parameter" {
    try expectPrivateReferencesAtCreation("class Box{static #value=1;static read(value=this.#value){return value;}}");
}
test "#4819 private reference creation extracted method default parameter" {
    try expectPrivateReferencesAtCreation("class Box{#value=1;#read(value=this.#value){return value;}read(){return this.#read();}}");
}
test "#4819 private reference creation captured method default parameter" {
    try expectPrivateReferencesAtCreation("class Box{static #value=1;static #read(value=Box.#value){return value;}static read(){return this.#read();}}");
}
test "#4819 private reference creation static block owner" {
    try expectPrivateReferencesAtCreation("class Box{static #value=1;static{this.read=this.#value;}}");
}

fn expectES5PrivateReferencesAtCreation(source: []const u8) !void {
    return expectLoweredClassPrivateReferencesAtCreation(source, false);
}

fn expectLoweredClassPrivateReferencesAtCreation(source: []const u8, native_class: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(if (native_class) .es2015 else .es5),
        .use_define_for_class_fields = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    var owner: ast.NodeIndex = .none;
    var start: u32 = std.math.maxInt(u32);
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration and node.span.start < start) {
            owner = @fromBackingInt(@intCast(raw));
            start = node.span.start;
        }
    }
    try std.testing.expect(!owner.isNone());
    const class = parser.ast.getNode(owner);
    const binding = parser.ast.readExtraNode(class.data.extra, ast.ClassExtra.name);
    const self_id = analyzer.class_self_symbol_map.get(@backingInt(owner)).?;
    const class_scope = analyzer.symbols.items[self_id].scope_id;
    const output_scope = analyzer.scopes.items[class_scope.toIndex()].parent;
    transformer.current_scope = class_scope;
    transformer.current_class_name_node = binding;
    transformer.current_class_self_symbol_id = self_id;
    try transformer.buildBlockRenameMap();
    const root = if (native_class)
        try transformer.visitNode(owner)
    else
        try @import("es2015_class.zig").ES2015Class(Transformer).lowerClassDeclaration(&transformer, owner, class);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_exact_symbol_refs.items.len);
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const Work = struct { node: ast.NodeIndex, scope: ScopeId };
    const editor = &transformer.semantic_editor.?;
    var stack: std.ArrayList(Work) = .empty;
    try stack.append(allocator, .{ .node = root, .scope = output_scope });
    for (transformer.pending_nodes.items) |node| try stack.append(allocator, .{ .node = node, .scope = output_scope });
    for (transformer.trailing_nodes.items) |node| try stack.append(allocator, .{ .node = node, .scope = output_scope });
    var references: usize = 0;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = transformer.ast.getNode(work.node);
        const scope = transformer.outputOwnedScope(work.node) orelse work.scope;
        if (@backingInt(work.node) >= transformer.parser_node_count and
            (node.tag == .function_expression or node.tag == .function_declaration or
                node.tag == .arrow_function_expression or node.tag == .method_definition))
        {
            const function_scope = transformer.outputOwnedScope(work.node) orelse return error.MissingGeneratedFunctionScope;
            try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, editor.scopes.items[function_scope.toIndex()].kind);
        }
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
            if (transformer.getSymbolIdAt(work.node)) |id| {
                if (transformer.private_helper_symbol_ids.contains(id)) {
                    const reference = (try editor.referenceForNode(work.node)).?;
                    try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                    try std.testing.expectEqual(scope, reference.scope_id);
                    try std.testing.expectEqual(node.tag == .identifier_reference, reference.flags.read);
                    try std.testing.expectEqual(node.tag == .assignment_target_identifier, reference.flags.write);
                    references += 1;
                }
            }
        }
        var children = @import("../parser/ast_walk.zig").children(transformer.ast, node);
        while (children.next()) |child| try stack.append(allocator, .{ .node = child, .scope = scope });
    }
    try std.testing.expect(references > 0);
}

test "#4819 private reference creation ES5 static descriptor" {
    try expectES5PrivateReferencesAtCreation("class Box{static #value=1;static read(){return this.#value;}}");
}

test "#4819 private reference creation ES5 nested same-name arrow" {
    try expectES5PrivateReferencesAtCreation("class Box{static #value=1;static read=()=>{class Box{static #value=2;static read(){return this.#value;}}return Box.read();};}");
}

test "#4819 private reference creation ES5 implicit base constructor" {
    try expectES5PrivateReferencesAtCreation("class Box{#value=1;read(){return this.#value;}}");
}

test "#4819 private reference creation ES5 implicit derived constructor" {
    try expectES5PrivateReferencesAtCreation("class Box extends Base{#value=1;read(){return this.#value;}}");
}

test "#4819 private reference creation ES5 existing non-simple constructor" {
    try expectES5PrivateReferencesAtCreation("class Box{constructor(value=1){this.value=value;}#value=2;read(){return this.#value;}}");
}

test "#4819 private reference creation ES5 static method descriptor" {
    try expectES5PrivateReferencesAtCreation("class Box{static #read(){return 1;}static run(){return this.#read();}}");
}

test "#4819 private reference creation ES5 instance method initialization" {
    try expectES5PrivateReferencesAtCreation("class Box{#read(){return 1;}run(){return this.#read();}}");
}

test "#4819 private reference creation ES5 static getter descriptor" {
    try expectES5PrivateReferencesAtCreation("class Box{static get #value(){return 1;}static run(){return this.#value;}}");
}

test "#4819 private reference creation ES5 accessor shared brand" {
    try expectES5PrivateReferencesAtCreation("class Box{get #value(){return 1;}set #value(value){this.seen=value;}run(){this.#value=2;return this.#value;}}");
}

test "#4819 private reference creation ES5 computed field and rest constructor" {
    try expectES5PrivateReferencesAtCreation("const _value=9;class Box{#value=1;['arrow']=()=>this.#value;constructor(...args){this.args=args;}}");
}

test "#4819 private reference creation ES5 readonly write-only method" {
    try expectES5PrivateReferencesAtCreation("class Box{static #write(){try{Box=1;}catch(error){return error.name;}}static run(){return this.#write();}}");
}

test "#4819 private reference creation generator switch owns native helper bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function* build(){class Box{#read(){return 1;}read(){return this.#read();}}yield Box;}");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var options: TransformOptions = .{ .unsupported = TransformOptions.compat.fromESTarget(.es2021) };
    options.unsupported.generator = true;
    var transformer = try Transformer.init(allocator, &parser.ast, options);
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    var function: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_declaration) function = @fromBackingInt(@intCast(raw));
    }
    const source_scope = transformer.outputOwnedScope(function).?;
    const body = transformer.ast.readExtraNode(transformer.ast.getNode(function).data.extra, ast.FunctionExtra.body);
    transformer.current_scope = source_scope;
    try transformer.buildBlockRenameMap();
    const Generator = @import("es2015_generator.zig").ES2015Generator(Transformer);
    var frame = try Generator.enterStateMachineTempsForScope(&transformer, source_scope);
    defer Generator.leaveStateMachineTemps(&transformer, &frame);
    const built = try Generator.buildStateMachine(&transformer, body, transformer.ast.getNode(function).span, source_scope);
    const scope = transformer.outputOwnedScope(built.body).?;
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.switch_block, editor.scopes.items[scope.toIndex()].kind);
    try std.testing.expectEqual(source_scope, editor.scopes.items[scope.toIndex()].parent);
    var functions: usize = 0;
    var ids = transformer.private_helper_symbol_ids.iterator();
    while (ids.next()) |entry| {
        const id = entry.key_ptr.*;
        const symbol = editor.symbols.items[id];
        if (symbol.kind != .function_decl) continue;
        try std.testing.expectEqual(scope, symbol.scope_id);
        functions += 1;
    }
    try std.testing.expect(functions > 0);
    const wrapper_nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(allocator, transformer.ast, built.var_decl);
    var wrapper_bindings: usize = 0;
    for (wrapper_nodes) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
        const id = transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))) orelse continue;
        if (!transformer.private_helper_symbol_ids.contains(id)) continue;
        try std.testing.expectEqual(source_scope, editor.symbols.items[id].scope_id);
        wrapper_bindings += 1;
    }
    try std.testing.expect(wrapper_bindings > 0);
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(allocator, transformer.ast, built.body);
    var references: usize = 0;
    for (live) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        if (transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw)))) |id| {
            if (!transformer.private_helper_symbol_ids.contains(id)) continue;
            const reference = (try editor.referenceForNode(@fromBackingInt(@intCast(raw)))).?;
            try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
            var cursor = reference.scope_id;
            var visible = false;
            for (0..editor.scopes.items.len) |_| {
                if (cursor.isNone()) break;
                if (cursor == editor.symbols.items[id].scope_id) {
                    visible = true;
                    break;
                }
                cursor = editor.scopes.items[cursor.toIndex()].parent;
            }
            try std.testing.expect(visible);
            references += 1;
        }
    }
    try std.testing.expect(references > 0);

    // A callback-local temp adds a block around the already-owned switch.
    // Its producer must attach that new lexical parent before finalization.
    const temp_start = transformer.temp_var_counter;
    _ = try @import("es_helpers.zig").makeTempVarSpan(&transformer);
    const wrapped = try transformer.hoistStateMachineTempsAndRestore(built.body, temp_start, transformer.ast.getNode(function).span, &frame.callback_temps);
    try std.testing.expect(wrapped != built.body);
    const block_scope = transformer.outputOwnedScope(wrapped).?;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, editor.scopes.items[block_scope.toIndex()].kind);
    try std.testing.expectEqual(source_scope, editor.scopes.items[block_scope.toIndex()].parent);
    try std.testing.expectEqual(scope, transformer.outputOwnedScope(built.body).?);
    try std.testing.expectEqual(block_scope, editor.scopes.items[scope.toIndex()].parent);
}

test "#4819 private reference creation ES5 static method called before initialization" {
    try expectES5PrivateReferencesAtCreation("class Box{static read=this.#method();static #method(){return 9;}}console.log(Box.read);");
}

test "#4819 private reference creation ES5 private field calls static method" {
    try expectES5PrivateReferencesAtCreation("class Box{static #value=this.#method();static #method(){return 9;}static read(){return this.#value;}}console.log(Box.read());");
}

test "#4819 private reference creation ES5 generated auto-accessor getter" {
    try expectES5PrivateReferencesAtCreation("function build(start){class Counter{accessor value=start;add(value){this.value+=value;return this.value;}}return new Counter().add(2);}console.log(build(40));");
}

test "#4819 private reference creation ES5 generated static auto-accessor getter" {
    try expectES5PrivateReferencesAtCreation("class Counter{static accessor value=1;static add(value){this.value+=value;return this.value;}}console.log(Counter.add(2));");
}

test "#4819 private reference creation ES5 generated computed auto-accessor getter" {
    try expectES5PrivateReferencesAtCreation("const key='value';class Counter{accessor [key]=1;add(value){this[key]+=value;return this[key];}}console.log(new Counter().add(2));");
}

test "#4819 private reference creation native generated auto-accessor getter" {
    try expectLoweredClassPrivateReferencesAtCreation("class Counter{accessor value=1;add(value){this.value+=value;return this.value;}}console.log(new Counter().add(2));", true);
}

test "#4819 private reference creation native generated static auto-accessor getter" {
    try expectLoweredClassPrivateReferencesAtCreation("class Counter{static accessor value=1;static add(value){this.value+=value;return this.value;}}console.log(Counter.add(2));", true);
}

test "#4819 private reference creation native generated computed auto-accessor getter" {
    try expectLoweredClassPrivateReferencesAtCreation("const key='value';class Counter{accessor [key]=1;add(value){this[key]+=value;return this[key];}}console.log(new Counter().add(2));", true);
}
