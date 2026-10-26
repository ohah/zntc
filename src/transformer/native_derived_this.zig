//! A native derived constructor's lexical-this cell is initialized by the
//! successful super call, rather than reading uninitialized this at entry.
const ast = @import("../parser/ast.zig");
const helpers = @import("es_helpers.zig");
const NodeIndex = ast.NodeIndex;

pub fn needsCell(self: anytype, owner: NodeIndex, method: ast.Node) !bool {
    return needsCellInScope(self, owner, method, self.capture_scope, false);
}

pub fn needsCellInScope(self: anytype, owner: NodeIndex, method: ast.Node, constructor_scope: @import("../semantic/scope.zig").ScopeId, allow_native_fields: bool) !bool {
    if (!self.semantic_edit_enabled or self.options.unsupported.class or !self.options.unsupported.arrow) return false;
    const class_idx = helpers.classConstructorOwner(self, owner, method) orelse return false;
    const class = self.ast.getNode(class_idx);
    if (self.ast.readExtraNode(class.data.extra, ast.ClassExtra.super).isNone()) return false;
    // The editor is lazy: direct source visitors still own the initial scopes.
    // An eval in any lexical descendant may observe a new constructor cell,
    // including an ordinary function that does not share lexical this.
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (constructor_scope.isNone() or constructor_scope.toIndex() >= scopes.len or scopes[constructor_scope.toIndex()].subtree_has_direct_eval) return false;
    const body = self.ast.getNode(self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body));
    for (self.ast.extra_data.items[body.data.list.start .. body.data.list.start + body.data.list.len]) |raw| {
        const member = self.ast.nodes.items[raw];
        if (member.tag != .property_definition and member.tag != .accessor_property) continue;
        const flags = self.ast.readExtra(member.data.extra, ast.PropertyExtra.flags);
        if (flags & (ast.PropertyFlags.is_static | ast.PropertyFlags.is_abstract | ast.PropertyFlags.is_declare) != 0) continue;
        // Native fields run inside super(), before its result can initialize
        // this cell. Their separate environment/timing producer is mandatory.
        if (!allow_native_fields and !@import("native_parameter_cells.zig").instanceMemberMoves(self, member, self.options.unsupported.privateLoweringPlan().fields, !self.options.use_define_for_class_fields)) return false;
    }
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    try self.scratch.append(self.allocator, self.ast.readExtraNode(method.data.extra, ast.MethodExtra.body));
    var found = false;
    while (self.scratch.items.len > scratch_top) {
        const idx = self.scratch.pop().?;
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .static_block => continue,
            .method_definition, .property_definition, .accessor_property => {
                const method_member = node.tag == .method_definition;
                try self.scratch.append(self.allocator, self.ast.readExtraNode(node.data.extra, 0));
                const start = self.ast.readExtra(node.data.extra, if (method_member) ast.MethodExtra.deco_start else ast.PropertyExtra.deco_start);
                const len = self.ast.readExtra(node.data.extra, if (method_member) ast.MethodExtra.deco_len else ast.PropertyExtra.deco_len);
                for (self.ast.extra_data.items[start .. start + len]) |raw| try self.scratch.append(self.allocator, @fromBackingInt(raw));
                continue;
            },
            else => {},
        }
        // Preserve the existing dynamic-environment retention boundary.
        if (node.tag == .with_statement or @import("static_class_capture.zig").isDirectEvalCall(self, node)) return false;
        if (node.tag == .arrow_function_expression and (try @import("es2015_arrow.zig").ES2015Arrow(@TypeOf(self.*)).lexicalCaptures(self, idx)).this_value) found = true;
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try self.scratch.append(self.allocator, child);
    }
    return found;
}

pub fn initializeAfterSuper(self: anytype, callee: NodeIndex, call: NodeIndex, span: @import("../lexer/token.zig").Span) !NodeIndex {
    if (callee.isNone() or self.ast.getNode(callee).tag != .super_expression) return call;
    const plan = @import("transformer/semantic_edit.zig").nativeFieldCaptureOwner(self) orelse return call;
    if (!plan.initialize_on_super) return call;
    const symbol = plan.symbol_id orelse @panic("native super cell has no creation identity");
    const declaration = self.ast.getNode(plan.this_declaration);
    const start = self.ast.readExtra(declaration.data.extra, 1);
    const declarator: NodeIndex = @fromBackingInt(self.ast.extra_data.items[start]);
    const binding = self.ast.getNode(self.ast.readExtraNode(self.ast.getNode(declarator).data.extra, 0));
    const target = try helpers.makeTempRefFromIdentity(self, .{ .span = binding.data.string_ref, .symbol_id = @fromBackingInt(symbol), .owner_scope = plan.scope, .reference_scope = self.current_scope }, span, .{ .write = true });
    const initialized = try helpers.makeAssignExpr(self, target, call, span, @backingInt(@import("../lexer/token.zig").Kind.eq));
    try self.generated_super_call_assignments.put(self.allocator, @backingInt(initialized), .{
        .constructor_frame = self.capture_frame,
        .constructor_scope = plan.scope,
        .use_scope = self.current_scope,
        .target_symbol = @fromBackingInt(symbol),
        .native = true,
    });
    return initialized;
}

test "native derived this cell preserves twelve constructor lifetime contexts" {
    const std = @import("std");
    const sources = [_][]const u8{
        "class P{}class D extends P{constructor(_this=11){const f=()=>[this,_this];super();console.log(f()[0]===this,f()[1])}}new D", "class P{}class D extends P{constructor(){const f=()=>this;function run(){return()=>this}const own=run.call({value:9});super();console.log(f()===this,own().value)}}new D", "class P{};class D extends P{constructor(){try{const f=()=>this;throw Error('heritage')}catch(e){console.log(e.message)}super()}}new D()", "class P{}class D extends P{constructor(){const f=()=>this;try{f()}catch(e){console.log(e.name)}super();console.log(f()===this)}}new D", "class P{}class D extends P{constructor(flag){const f=()=>this;if(flag)super();else super();console.log(f()===this)}}new D(true);new D(false)", "class P{}class D extends P{constructor(){const f=()=>this;console.log((super(),f()===this))}}new D", "class P{constructor(){throw Error('base')}}class D extends P{constructor(){const f=()=>this;try{super()}catch(e){console.log(e.message)}try{f()}catch(e){console.log(e.name)}return {}}}new D", "class P{}class D extends P{constructor(){const f=()=>this;return {f}}}const x=new D;try{x.f()}catch(e){console.log(e.name)}", "class P{}class D extends P{constructor(){const f=()=>this;super();try{super()}catch(e){console.log(e.name)}console.log(f()===this)}}new D", "class P{}class D extends P{constructor(){const f=()=>()=>this;super();console.log(f()()===this)}}new D", "class P{}class D extends P{constructor(){const f=function(){return this};super();console.log(f()===undefined)}}new D", "class P{constructor(){const f=()=>this;console.log(f()===this)}}new P",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const native = try std.process.run(alloc, std.testing.io, .{ .argv = &.{ "node", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        for ([_]bool{ false, true }) |define| for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(alloc, source, "input.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80),
                .use_define_for_class_fields = define,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(alloc, std.testing.io, .{ .argv = &.{ "node", "-e", result.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("source:{s}\ncode:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ source, result.code, native.stdout, actual.stdout, actual.stderr });
            try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "native derived this cell has exact read write scope at creation" {
    const std = @import("std");
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "class P{}class D extends P{constructor(flag=1){const f=()=>this;if(flag){super()}else{super()}console.log(f()===this)}}new D(true);new D(false)";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80) });
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
    try std.testing.expectEqual(@as(usize, 1), t.capture_binding_ids.count());
    var ids = t.capture_binding_ids.valueIterator();
    const sid = ids.next().?.*;
    const Work = struct { node: NodeIndex, scope: ScopeId, parent: NodeIndex = .none };
    var stack: std.ArrayList(Work) = .empty;
    try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0) });
    var bindings: usize = 0;
    var reads: usize = 0;
    var writes: usize = 0;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = t.ast.getNode(work.node);
        const scope = t.outputOwnedScope(work.node) orelse work.scope;
        if (t.getSymbolIdAt(work.node)) |id| if (id == sid) {
            if (node.tag == .binding_identifier) {
                try std.testing.expectEqual(scope, t.semantic_editor.?.symbols.items[id].scope_id);
                const declarator = t.ast.getNode(work.parent);
                try std.testing.expect(t.ast.readExtraNode(declarator.data.extra, 2).isNone());
                bindings += 1;
            } else {
                const reference = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingReferenceAtCreation;
                try std.testing.expectEqual(scope, reference.scope_id);
                try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                if (reference.flags.write) {
                    try std.testing.expect(!reference.flags.read);
                    const assignment = t.ast.getNode(work.parent);
                    try std.testing.expectEqual(ast.Node.Tag.assignment_expression, assignment.tag);
                    try std.testing.expectEqual(work.node, assignment.data.binary.left);
                    const call = t.ast.getNode(assignment.data.binary.right);
                    try std.testing.expectEqual(ast.Node.Tag.call_expression, call.tag);
                    try std.testing.expectEqual(ast.Node.Tag.super_expression, t.ast.getNode(t.ast.readExtraNode(call.data.extra, 0)).tag);
                    writes += 1;
                } else {
                    try std.testing.expect(reference.flags.read);
                    reads += 1;
                }
            }
        };
        var children = @import("../parser/ast_walk.zig").children(t.ast, node);
        while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope, .parent = work.node });
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 2), writes);
}

test "native derived this cell declaration is uninitialized at the binding producer boundary" {
    const std = @import("std");
    const Transformer = @import("transformer.zig").Transformer;
    for ([_]bool{ false, true }) |field_binding_first| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = "class P{}class D extends P{read=()=>this;constructor(){const f=()=>this;super()}}";
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        var t = try Transformer.init(a, &parser.ast, .{
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
        t.semantic_edit_enabled = true;
        var constructor: NodeIndex = .none;
        for (t.ast.nodes.items, 0..) |node, raw| {
            if (helpers.isClassConstructorMethod(&t, @fromBackingInt(@intCast(raw)), node)) constructor = @fromBackingInt(@intCast(raw));
        }
        try std.testing.expect(!constructor.isNone());
        t.current_scope = t.originalFunctionScope(constructor);
        const frame = helpers.pushCaptureFrame(&t);
        defer helpers.popCaptureFrame(&t, frame);
        var plan: @import("transformer.zig").NativeFieldCapturePlan = .{
            .derived = true,
            .frame = frame.active_frame,
            .scope = t.capture_scope,
            .initialize_on_super = !field_binding_first,
        };
        const semantic_edit = @import("transformer/semantic_edit.zig");
        try semantic_edit.ensureNativeConstructorCaptureBinding(&t, &plan, t.ast.getNode(constructor).span);
        const original_declaration = plan.this_declaration;
        const original_symbol = plan.symbol_id.?;
        const declaration = t.ast.getNode(original_declaration);
        const start = t.ast.readExtra(declaration.data.extra, 1);
        const declarator_idx: NodeIndex = @fromBackingInt(t.ast.extra_data.items[start]);
        const declarator = t.ast.getNode(declarator_idx);
        const binding = t.ast.readExtraNode(declarator.data.extra, 0);
        try std.testing.expectEqual(original_symbol, t.getSymbolIdAt(binding).?);
        try std.testing.expectEqual(plan.scope, t.semantic_editor.?.symbols.items[original_symbol].scope_id);
        if (field_binding_first) {
            const old_initializer = t.ast.readExtraNode(declarator.data.extra, 2);
            try std.testing.expectEqual(ast.Node.Tag.this_expression, t.ast.getNode(old_initializer).tag);
            plan.initialize_on_super = true;
            try semantic_edit.ensureNativeConstructorCaptureBinding(&t, &plan, t.ast.getNode(constructor).span);
            try std.testing.expectEqual(original_declaration, plan.this_declaration);
            try std.testing.expectEqual(original_symbol, plan.symbol_id.?);
        }
        // Check immediately after the producer, before a later capture use can
        // revisit the declaration. The descriptor check is independent of the
        // numeric initializer slot used by the write above.
        try std.testing.expect(t.ast.readExtraNode(declarator.data.extra, 2).isNone());
        var children = @import("../parser/ast_walk.zig").children(t.ast, declarator);
        var actual_children: usize = 0;
        while (children.next()) |child| {
            if (child.isNone()) continue;
            try std.testing.expectEqual(binding, child);
            actual_children += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), actual_children);
    }
}
