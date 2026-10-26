//! Assemble a guard around an already visited native constructor body.
//! The caller owns eligibility, the first native-field publication, source-try
//! probes and final statement-coordinate publication. This builder does not
//! admit a transform or rediscover a binding from a spelling.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;
const helpers = @import("es_helpers.zig");

fn block(self: anytype, statements: []const ast.NodeIndex, span: Span) !ast.NodeIndex {
    return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(statements) } });
}

fn reference(self: anytype, identity: helpers.TempIdentityCapture, scope: ScopeId, write: bool, span: Span) !ast.NodeIndex {
    if (!self.semantic_edit_enabled or identity.symbol_id == null or identity.owner_scope.isNone() or scope.isNone())
        @panic("native constructor guard reference lacks its exact producer identity");
    var use = identity;
    use.reference_scope = scope;
    const node = try helpers.makeTempRefFromIdentity(self, use, span, if (write) .{ .write = true } else .{ .read = true });
    if (write) self.ast.nodes.items[@backingInt(node)].tag = .assignment_target_identifier;
    return node;
}

fn binding(self: anytype, name: []const u8, scope: ScopeId, kind: @import("../semantic/symbol.zig").SymbolKind, span: Span) !struct { node: ast.NodeIndex, identity: helpers.TempIdentityCapture } {
    var counter: u32 = 0;
    const selected = try self.buildUniqueNameAvoidingDynamicEval(name, &counter, scope);
    const node = try helpers.makeExactSyntheticBinding(self, selected);
    const id = (try self.declareSyntheticInScope(node, span, kind, scope)) orelse @panic("native constructor guard has no exact binding");
    return .{ .node = node, .identity = .{ .span = self.ast.getNode(node).data.string_ref, .symbol_id = id, .owner_scope = scope } };
}

fn operation(self: anytype, code: u32, value: ast.NodeIndex, scope: ScopeId, span: Span) !ast.NodeIndex {
    const saved = self.current_scope;
    self.current_scope = scope;
    defer self.current_scope = saved;
    self.runtime_helpers.derived_constructor = true;
    const callee = try helpers.makeRuntimeHelperRef(self, "__nativeCtorThis");
    const number = try helpers.makeNumericLiteral(self, code);
    return helpers.makeCallExpr(self, callee, &.{ number, value }, span);
}

pub fn publish(self: anytype, scope: ScopeId, span: Span) !ast.NodeIndex {
    const native_this = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } });
    return operation(self, 1, native_this, scope, span);
}

fn setter(self: anytype, alias: helpers.TempIdentityCapture, parent: ScopeId, span: Span) !ast.NodeIndex {
    const parameters = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{}), span);
    const body = try block(self, &.{}, span);
    const extra = try self.ast.addExtras(&.{ @backingInt(ast.NodeIndex.none), @backingInt(parameters), @backingInt(body), 0, @backingInt(ast.NodeIndex.none) });
    const function = try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{ .extra = extra } });
    const scope = try self.addGeneratedFunctionScope(parent, function);
    const parameter = try binding(self, "_ctorValue", scope, .parameter, span);
    self.ast.nodes.items[@backingInt(parameters)].data.list = try self.ast.addNodeList(&.{parameter.node});
    const assignment = try helpers.makeAssignStmt(self, try reference(self, alias, scope, true, span), try reference(self, parameter.identity, scope, false, span), span, 0);
    self.ast.nodes.items[@backingInt(body)].data.list = try self.ast.addNodeList(&.{assignment});
    return function;
}

/// Probe native `this` after a source try-body and before its catch parameter
/// or finally runs. Add this after visiting source syntax so it cannot be
/// rewritten as a lexical-this capture itself.
pub fn probe(self: anytype, alias: helpers.TempIdentityCapture, parent: ScopeId, span: Span) !ast.NodeIndex {
    const body = try block(self, &.{}, span);
    const scope = try self.addGeneratedScope(parent, body, .block);
    const native_this = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } });
    const assignment = try helpers.makeAssignStmt(self, try reference(self, alias, scope, true, span), native_this, span, 0);
    self.ast.nodes.items[@backingInt(body)].data.list = try self.ast.addNodeList(&.{assignment});
    const caught_body = try block(self, &.{}, span);
    const caught = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{ .left = .none, .right = caught_body, .flags = 0 } } });
    const catch_scope = try self.addGeneratedCatchScope(parent, caught);
    const ignored = try binding(self, "_ctorIgnored", catch_scope, .catch_binding, span);
    self.ast.nodes.items[@backingInt(caught)].data.binary.left = ignored.node;
    _ = try self.addGeneratedScope(catch_scope, caught_body, .block);
    return self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{ .a = body, .b = caught, .c = .none } } });
}

/// A private-brand failure can happen after BindThisBinding but before the
/// first field. Publish native this before a source catch parameter/finally
/// can call an escaped callback. Nested functions own different this values.
pub fn instrumentSourceTries(self: anytype, body: ast.NodeIndex, alias: helpers.TempIdentityCapture) !void {
    const Work = struct { node: ast.NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var attempts: std.ArrayList(Work) = .empty;
    defer attempts.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = body, .scope = self.outputOwnedScope(body) orelse @panic("native constructor source body has no owner") });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = self.ast.getNode(work.node);
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression, .static_block => continue,
            else => {},
        }
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (node.tag == .try_statement) try attempts.append(self.allocator, .{ .node = work.node, .scope = scope });
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .scope = scope });
    }
    // Inner boundaries are complete before an outer generated block takes
    // ownership of their existing scope frontiers.
    var index = attempts.items.len;
    while (index != 0) {
        index -= 1;
        const work = attempts.items[index];
        const original = self.ast.getNode(work.node);
        const original_body = original.data.ternary.a;
        const outer = try block(self, &.{}, original.span);
        const outer_scope = try self.addGeneratedScope(work.scope, outer, .block);
        if (self.outputOwnedScope(original_body)) |owned| {
            if (owned == work.scope) @panic("native constructor try body aliases its enclosing scope");
            try self.reparentGeneratedScope(owned, outer_scope);
        } else {
            const inner_scope = try self.addGeneratedScope(outer_scope, original_body, .block);
            try @import("class_strict_context.zig").moveSourceReferences(self, original_body, work.scope, work.scope, inner_scope);
            try @import("transformer/semantic_edit.zig").reparentGeneratedBodyScopes(self, work.scope, inner_scope, original_body);
        }
        const finalizer = try block(self, &.{}, original.span);
        const finally_scope = try self.addGeneratedScope(outer_scope, finalizer, .block);
        const native_probe = try probe(self, alias, finally_scope, original.span);
        self.ast.nodes.items[@backingInt(finalizer)].data.list = try self.ast.addNodeList(&.{native_probe});
        const attempt = try self.ast.addNode(.{ .tag = .try_statement, .span = original.span, .data = .{ .ternary = .{ .a = original_body, .b = .none, .c = finalizer } } });
        self.ast.nodes.items[@backingInt(outer)].data.list = try self.ast.addNodeList(&.{attempt});
        self.ast.nodes.items[@backingInt(work.node)].data.ternary.a = outer;
    }
}

/// `body` already owns its new lexical try ScopeId. Function declarations
/// have already been materialized by the exact function-cell producer.
pub fn wrap(self: anytype, body: ast.NodeIndex, storage: ast.NodeList, alias: helpers.TempIdentityCapture, constructor_scope: ScopeId, span: Span) !ast.NodeIndex {
    if (!self.semantic_edit_enabled or alias.symbol_id == null or alias.owner_scope != constructor_scope)
        @panic("native constructor guard requires its existing exact this cell");
    const own = self.outputOwnedScope(body) orelse @panic("guarded constructor body has no lexical owner");
    if (own == constructor_scope or self.outputScopeParent(own) != constructor_scope)
        @panic("guarded constructor body lost its actual try boundary");
    const frame = try binding(self, "_ctorFrame", constructor_scope, .variable_var, span);
    const begin = try operation(self, 0, try setter(self, alias, constructor_scope, span), constructor_scope, span);
    const declaration = try helpers.makeDeclarator(self, frame.node, begin, span);
    const frame_statement = try helpers.makeVarDeclaration(self, &.{declaration}, .@"var", span);
    const finalizer = try block(self, &.{}, span);
    const finally_scope = try self.addGeneratedScope(constructor_scope, finalizer, .block);
    const native_probe = try probe(self, alias, finally_scope, span);
    const finish = try operation(self, 2, try reference(self, frame.identity, finally_scope, false, span), finally_scope, span);
    const finish_statement = try helpers.makeExprStmt(self, finish, span);
    self.ast.nodes.items[@backingInt(finalizer)].data.list = try self.ast.addNodeList(&.{ native_probe, finish_statement });
    const attempt = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{ .a = body, .b = .none, .c = finalizer } } });
    var statements: std.ArrayList(ast.NodeIndex) = .empty;
    defer statements.deinit(self.allocator);
    for (0..storage.len) |i| try statements.append(self.allocator, self.ast.readExtraNode(storage.start, @intCast(i)));
    try statements.appendSlice(self.allocator, &.{ frame_statement, attempt });
    return block(self, statements.items, span);
}

test "native constructor guard assembles exact scopes and executes a native field callback" {
    try checkControl(
        "let saved;class P{}class D extends P{value=saved();constructor(){var cell;saved=function(){return cell};super();console.log(this.value===this)}}new D",
        "let saved;class P{}class D extends P{value=saved();constructor(){saved=()=>this;super();console.log(this.value===this)}}new D",
    );
    try checkControl(
        "let shared={},saved;class P{constructor(){return shared}}class D extends P{#method(){}value=1;constructor(){var cell;saved=function(){return cell};try{super()}catch({missing=(console.log(saved()===shared),7)}){console.log(missing)}}}new D;new D",
        "let shared={},saved;class P{constructor(){return shared}}class D extends P{#method(){}value=1;constructor(){saved=()=>this;try{super()}catch({missing=(console.log(saved()===shared),7)}){console.log(missing)}}}new D;new D",
    );
}

fn checkControl(source: []const u8, native_source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const Transformer = @import("transformer.zig").Transformer;
    var t = try Transformer.init(a, &parser.ast, .{});
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
    var constructor: ast.NodeIndex = .none;
    var field: ast.NodeIndex = .none;
    var alias_binding: ast.NodeIndex = .none;
    for (t.ast.nodes.items, 0..) |node, raw| {
        const index: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
        if (helpers.isClassConstructorMethod(&t, index, node)) constructor = index;
        if (node.tag == .property_definition) field = index;
        if (node.tag == .binding_identifier and std.mem.eql(u8, t.ast.getText(node.data.string_ref), "cell")) alias_binding = index;
    }
    try std.testing.expect(!constructor.isNone() and !field.isNone() and !alias_binding.isNone());
    const constructor_scope = t.outputOwnedScope(constructor).?;
    t.current_scope = constructor_scope;
    const body = t.ast.readExtraNode(t.ast.getNode(constructor).data.extra, ast.MethodExtra.body);
    _ = try @import("native_constructor_body_scope.zig").prepare(&t, body, constructor_scope);
    const visited = try t.visitNode(body);
    const alias: helpers.TempIdentityCapture = .{ .span = t.ast.getNode(alias_binding).data.string_ref, .symbol_id = @fromBackingInt(t.getSymbolIdAt(alias_binding).?), .owner_scope = constructor_scope };
    try instrumentSourceTries(&t, visited, alias);
    const assembled = try wrap(&t, visited, try t.ast.addNodeList(&.{}), alias, constructor_scope, t.ast.getNode(constructor).span);
    t.ast.extra_data.items[t.ast.getNode(constructor).data.extra + ast.MethodExtra.body] = @backingInt(assembled);
    const owner = helpers.classConstructorOwner(&t, constructor, t.ast.getNode(constructor)).?;
    const field_scope = t.outputOwnedScope(field) orelse t.outputOwnedScope(owner).?;
    const field_node = t.ast.getNode(field);
    const original_value = t.ast.readExtraNode(field_node.data.extra, ast.PropertyExtra.init);
    const publication = try publish(&t, field_scope, field_node.span);
    const value = try t.ast.addNode(.{ .tag = .sequence_expression, .span = field_node.span, .data = .{ .list = try t.ast.addNodeList(&.{ publication, original_value }) } });
    t.ast.extra_data.items[field_node.data.extra + ast.PropertyExtra.init] = @backingInt(value);
    const utils = @import("output_scope_test_utils.zig");
    var parents = try utils.buildParentMap(a, t.ast, root);
    defer parents.deinit(a);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(a);
    for (t.ast.nodes.items, 0..) |_, raw| {
        const node: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node != root and !parents.contains(@intCast(raw))) continue;
        if (t.outputOwnedScope(node)) |scope| try owners.put(a, @intCast(raw), @backingInt(scope));
    }
    for (t.semantic_editor.?.references.items) |row| {
        if (row.flags.declare or row.node_index.isNone() or !parents.contains(@backingInt(row.node_index))) continue;
        const actual = utils.expectedScope(t.ast, root, &parents, &owners, @backingInt(row.node_index)) orelse return error.MissingActualScope;
        try std.testing.expectEqual(actual, row.scope_id);
    }
    var codegen = @import("../codegen/codegen.zig").Codegen.init(a, t.ast);
    const output = try codegen.generate(root);
    const executable = try std.fmt.allocPrint(a, "{s}\n{s}", .{ @import("../bundler/runtime_helpers.zig").DERIVED_CONSTRUCTOR_RUNTIME, output });
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", native_source } });
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", executable } });
    if (actual.term != .exited or actual.term.exited != 0) std.debug.print("native constructor guard output:\n{s}\nstderr:{s}\n", .{ executable, actual.stderr });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}
