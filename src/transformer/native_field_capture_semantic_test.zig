const std = @import("std");

const Case = struct { name: []const u8, source: []const u8, capture: bool = true, super_writes: usize = 0 };
const cases = [_]Case{
    .{ .name = "derived body capture before and after super", .super_writes = 1, .source = "class Parent{};class Box extends Parent{value=7;constructor(){const early=()=>this;try{console.log(early())}catch(e){console.log(e.name)}super();console.log(early()===this)}}new Box();" },
    .{ .name = "derived shared capture before and after super", .super_writes = 1, .source = "class Parent{};class Box extends Parent{value=7;read=()=>this.value;constructor(){const early=()=>this;try{console.log(early())}catch(e){console.log(e.name)}super();console.log(early()===this)}}new Box();" },
    .{ .name = "global alias collision", .source = "const _this=11;class Box{value=7;read=()=>[this.value,_this]}console.log(JSON.stringify(new Box().read()));" },
    .{ .name = "native non-simple constructor collision", .source = "class Box{value=7;read=()=>this.value;constructor(_this=11){this.other=_this}}const box=new Box();console.log(box.read(),box.other);" },
    .{ .name = "implicit base", .source = "class Box{value=7;read=()=>this.value}console.log(new Box().read());" },
    .{ .name = "constructor before fields", .source = "class Box{constructor(){this.other=2}value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.other);" },
    .{ .name = "constructor body and field arrows", .source = "class Box{value=7;read=()=>this.value;constructor(){this.body=()=>this.value}}const box=new Box();console.log(box.read(),box.body());" },
    .{ .name = "constructor collision", .source = "class Box{value=7;read=()=>this.value;constructor(_this){this.other=_this}}const box=new Box(11);console.log(box.read(),box.other);" },
    .{ .name = "shared nested field arrows", .source = "class Box{value=7;first=()=>this.value;second=()=>()=>this.value+1}const box=new Box();console.log(box.first(),box.second()());" },
    .{ .name = "implicit derived", .source = "class Parent{constructor(){this.base=1}}class Box extends Parent{value=7;read=()=>[this.value,this.base]}console.log(JSON.stringify(new Box().read()));" },
    .{ .name = "explicit derived", .source = "class Parent{constructor(){this.base=1}}class Box extends Parent{value=7;read=()=>this.value;constructor(){super();this.extra=2}}const box=new Box();console.log(box.read(),box.extra);" },
    .{ .name = "replacement super object", .source = "class Parent{constructor(){return{value:4}}}class Box extends Parent{value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.value);" },
    .{ .name = "outer frame restoration", .source = "function build(){const outer=()=>this;class Box{value=7;read=()=>this.value}return[outer().tag,new Box().read()]}console.log(JSON.stringify(build.call({tag:\"outer\"})));" },
    .{ .name = "field newtarget", .source = "class Box{value=7;read=()=>[this.value,new.target];constructor(){this.actual=new.target}}const box=new Box();console.log(JSON.stringify([box.read(),box.actual===Box]));" },
    .{ .name = "async field arrow", .source = "class Box{value=7;read=async()=>this.value}new Box().read().then(value=>console.log(value));" },
    .{ .name = "nested ordinary function boundary", .source = "class Box{read=(function(){return()=>this.value}).call({value:9})}console.log(new Box().read());", .capture = false },
    .{ .name = "constructor first shared storage", .source = "class Box{constructor(){this.body=()=>this.value}value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.body());" },
};

test "native field capture preserves source values across seventeen constructor contexts" {
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", case.source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        for ([_]bool{ false, true }) |define| for ([_]bool{ false, true }) |minify| {
            var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
            // Both modes here move initializers into their actual constructor.
            // Native retained fields have a separate initializer environment.
            if (define) unsupported.class_field = true;
            const result = try @import("../transpile.zig").transpile(a, case.source, "input.cjs", .{
                .unsupported = unsupported,
                .use_define_for_class_fields = define,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("case:{s} define={any} minify={any}\nsource:{s}\noutput:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ case.name, define, minify, case.source, result.code, native.stdout, actual.stdout, actual.stderr });
            try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "native field capture owns exact constructor storage and references before output walk" {
    const ast = @import("../parser/ast.zig");
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    for (cases) |case| {
        errdefer std.debug.print("field capture identity source: {s}\n", .{case.name});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
            .unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80),
            .use_define_for_class_fields = false,
        });
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
        const output = try t.visitNode(root);
        try std.testing.expect(t.native_field_capture_plan == null);
        const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, t.ast, output);
        var constructors: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (reachable) |raw| {
            const node = t.ast.nodes.items[raw];
            if (node.tag != .method_definition) continue;
            if (t.ast.readExtra(node.data.extra, ast.MethodExtra.flags) & ast.MethodFlags.is_static != 0) continue;
            const key = t.ast.getNode(t.ast.readExtraNode(node.data.extra, ast.MethodExtra.key));
            if (key.tag == .computed_property_key or !std.mem.eql(u8, t.ast.getText(key.data.string_ref), "constructor")) continue;
            const owner = t.outputOwnedScope(@fromBackingInt(raw)) orelse return error.MissingActualConstructorScope;
            try constructors.put(a, @backingInt(owner), {});
        }
        var captures: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var ids = t.capture_binding_ids.valueIterator();
        while (ids.next()) |id| {
            if (constructors.contains(@backingInt(t.semantic_editor.?.symbols.items[id.*].scope_id))) try captures.put(a, id.*, {});
        }
        try std.testing.expectEqual(@as(usize, if (case.capture) 1 else 0), captures.count());
        const Work = struct { node: ast.NodeIndex, scope: ScopeId, parent: ast.NodeIndex = .none };
        var stack: std.ArrayList(Work) = .empty;
        try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0) });
        var bindings: usize = 0;
        var references: usize = 0;
        var super_writes: usize = 0;
        while (stack.pop()) |work| {
            if (work.node.isNone()) continue;
            const node = t.ast.getNode(work.node);
            const scope = t.outputOwnedScope(work.node) orelse work.scope;
            if (t.getSymbolIdAt(work.node)) |id| if (captures.contains(id)) {
                if (node.tag == .binding_identifier) {
                    try std.testing.expectEqual(scope, t.semantic_editor.?.symbols.items[id].scope_id);
                    if (case.super_writes > 0) {
                        const declarator = t.ast.getNode(work.parent);
                        try std.testing.expect(t.ast.readExtraNode(declarator.data.extra, 1).isNone());
                    }
                    bindings += 1;
                } else if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                    const ref = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingCaptureReferenceAtBirth;
                    try std.testing.expectEqual(id, @backingInt(ref.symbol_id));
                    try std.testing.expectEqual(scope, ref.scope_id);
                    if (ref.flags.write) {
                        try std.testing.expect(!ref.flags.read);
                        const assignment = t.ast.getNode(work.parent);
                        try std.testing.expectEqual(ast.Node.Tag.assignment_expression, assignment.tag);
                        try std.testing.expectEqual(work.node, assignment.data.binary.left);
                        const call = t.ast.getNode(assignment.data.binary.right);
                        try std.testing.expectEqual(ast.Node.Tag.call_expression, call.tag);
                        try std.testing.expectEqual(ast.Node.Tag.super_expression, t.ast.getNode(t.ast.readExtraNode(call.data.extra, 0)).tag);
                        super_writes += 1;
                    } else try std.testing.expect(ref.flags.read);
                    references += 1;
                }
            };
            var children = @import("../parser/ast_walk.zig").children(t.ast, node);
            while (children.next()) |child| {
                const outside = node.tag == .method_definition and child == t.ast.readExtraNode(node.data.extra, ast.MethodExtra.key);
                try stack.append(a, .{ .node = child, .scope = if (outside) work.scope else scope, .parent = work.node });
            }
        }
        try std.testing.expectEqual(case.super_writes, super_writes);
        try std.testing.expectEqual(captures.count(), bindings);
        try std.testing.expect((references > 0) == case.capture);
    }
}

test "native field capture restores caller state at the field producer boundary" {
    const ast = @import("../parser/ast.zig");
    const helpers = @import("transformer/class_member_helpers.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "class Box{value=()=>this}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
        .unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80),
        .use_define_for_class_fields = false,
    });
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
    var class_node: ast.NodeIndex = .none;
    var property: ast.NodeIndex = .none;
    for (t.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_node = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node.tag == .property_definition) property = @fromBackingInt(@as(u32, @intCast(raw)));
    }
    const class_scope = t.outputOwnedScope(class_node) orelse return error.MissingSourceClassScope;
    t.current_scope = class_scope;
    const body = t.ast.readExtraNode(t.ast.getNode(class_node).data.extra, ast.ClassExtra.body);
    const plan = try helpers.prepareFieldInitializerPlan(&t, body, class_scope);
    var members: std.ArrayList(ast.NodeIndex) = .empty;
    var fields: std.ArrayList(helpers.FieldAssignment) = .empty;
    var decorators: std.ArrayList(helpers.MemberDecoratorInfo) = .empty;
    var parameter_decorators: std.ArrayList(ast.NodeIndex) = .empty;
    var constructor: ?ast.NodeIndex = null;
    var constructor_position: ?usize = null;
    var params: ast.NodeList = .{ .start = 0, .len = 0 };
    var context: helpers.ClassMemberContext = .{
        .field_initializer_plan = plan,
        .class_members = &members,
        .field_assignments = &fields,
        .member_decorators = &decorators,
        .existing_constructor = &constructor,
        .existing_constructor_pos = &constructor_position,
        .ctor_param_decos = &parameter_decorators,
        .ctor_params = &params,
    };
    const capture_scope = t.capture_scope;
    try helpers.classifyPropertyDefinition(&t, @backingInt(property), t.ast.getNode(property), &context);
    try std.testing.expectEqual(class_scope, t.current_scope);
    try std.testing.expectEqual(capture_scope, t.capture_scope);
    try std.testing.expectEqual(@as(u32, 0), t.capture_frame);
    try std.testing.expectEqual(@as(u32, 0), t.arrow_this_depth);
    try std.testing.expect(!t.needs_this_var and !t.needs_arguments_var and !t.super_call_this_alias);
    try std.testing.expect(t.native_field_capture_plan == null);
    try std.testing.expectEqual(@as(usize, 1), fields.items.len);
    const capture = context.field_initializer_plan.capture;
    try std.testing.expect(!capture.this_declaration.isNone());
    try std.testing.expectEqual(plan.scope, t.semantic_editor.?.symbols.items[capture.symbol_id.?].scope_id);
}
