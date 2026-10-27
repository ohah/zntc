//! Eligibility and creation-site handoffs for the native constructor bridge.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const helpers = @import("es_helpers.zig");
const guard = @import("native_constructor_guard.zig");

pub const Plan = struct {
    first_field: ast.NodeIndex,
    named_value: bool,
};

/// A moved-initializer producer supplies its actual reserved constructor
/// function scope. This records placement ownership, not timing eligibility.
pub fn registerPlacementOwner(self: anytype, scope: ScopeId) !void {
    if (!self.semantic_edit_enabled) return;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (scope.isNone() or scope.toIndex() >= scopes.len or scopes[scope.toIndex()].kind != .function)
        @panic("constructor placement producer has no actual function scope");
    try self.native_constructor_placement_scopes.put(self.allocator, @backingInt(scope), {});
}

pub fn publication(self: anytype, raw: u32) ?@import("transformer.zig").StatementPublication {
    const native = self.native_constructor_statement_handoffs.get(raw);
    const generator = self.generator_function_coordinate_handoffs.get(raw);
    if (native != null and generator != null and !std.meta.eql(native.?, generator.?))
        @panic("constructor and generator statement publications disagree");
    return native orelse generator;
}

/// Publish placement after actual owner assembly. Never infer binding identity.
pub fn projectCoordinates(self: anytype, root: ast.NodeIndex) !void {
    if (!self.semantic_edit_enabled or self.semantic_editor == null or
        (self.native_constructor_timing_plans.count() == 0 and self.native_constructor_placement_scopes.count() == 0 and self.native_constructor_reference_origins.count() == 0)) return;
    const coordinates = @import("../semantic/statement_coordinates.zig").collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("native constructor statement ownership is invalid: {s}", .{@errorName(err)}),
    };
    defer self.allocator.free(coordinates);
    const editor = &self.semantic_editor.?;
    var program_shifted = false;
    if (self.parser_node_count != 0) {
        const original = self.ast.getNode(@fromBackingInt(@as(u32, @intCast(self.parser_node_count - 1))));
        const output = self.ast.getNode(root);
        program_shifted = original.tag == .program and output.tag == .program and original.data.list.len != output.data.list.len;
    }
    // Class factories introduce nested statement lists even when the program
    // length stays constant. Reindex existing rows only; their IDs, use scopes
    // and publication eligibility remain the original producers' authority.
    const reindex_existing_positions = program_shifted or
        self.class_factory_statement_lists_changed or
        (self.options.unsupported.class and self.native_constructor_placement_scopes.count() != 0);
    var generated = self.native_constructor_reference_origins.iterator();
    while (generated.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= coordinates.len or coordinates[raw] == null) continue;
        const row = (editor.referenceForNode(@fromBackingInt(raw)) catch @panic("native constructor reference index is invalid")) orelse @panic("native constructor producer reference is missing");
        const known = entry.value_ptr.*;
        if (row.symbol_id != known.symbol_id or row.scope_id != known.scope or !std.meta.eql(row.flags, known.flags))
            @panic("native constructor reference changed its creation identity");
    }
    for (editor.references.items) |*row| {
        var selected = !row.node_index.isNone() and self.native_constructor_reference_origins.contains(@backingInt(row.node_index));
        var scope = row.scope_id;
        var hops: usize = 0;
        while (!selected and !scope.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
            if (scope.toIndex() >= editor.scopes.items.len) @panic("native constructor coordinate row has an invalid scope");
            if (self.native_constructor_timing_plans.contains(@backingInt(scope)) or self.native_constructor_placement_scopes.contains(@backingInt(scope))) {
                selected = true;
                break;
            }
            scope = editor.scopes.items[scope.toIndex()].parent;
        }
        // A helper-import prefix can shift other existing rows too. Reindex
        // their coordinates without granting constructor publication rights.
        if (!selected and !reindex_existing_positions) continue;
        const node = if (row.node_index.isNone()) row.declaration_node_index else row.node_index;
        if (node.isNone() or @backingInt(node) >= coordinates.len) continue;
        const actual = coordinates[@backingInt(node)] orelse continue;
        row.stmt_idx = actual.stmt_idx;
        row.scope_stmt_idx = actual.scope_stmt_idx;
        if (selected and !row.flags.declare) {
            try self.native_constructor_statement_nodes.put(self.allocator, @backingInt(node), {});
            try self.native_constructor_statement_handoffs.put(self.allocator, @backingInt(node), .{ .symbol_id = row.symbol_id, .scope = row.scope_id, .stmt = actual.stmt_idx, .scope_stmt = actual.scope_stmt_idx });
        }
    }
}

fn anonymousValue(self: anytype, value: ast.NodeIndex) bool {
    if (value.isNone()) return false;
    const node = self.ast.getNode(value);
    return switch (node.tag) {
        .parenthesized_expression => anonymousValue(self, node.data.unary.operand),
        .arrow_function_expression => true,
        .function_expression, .class_expression => self.ast.readExtraNode(node.data.extra, 0).isNone(),
        else => false,
    };
}

fn hasDeferredSuper(self: anytype, body: ast.NodeIndex) !bool {
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |index| {
        if (index.isNone()) continue;
        const node = self.ast.getNode(index);
        switch (node.tag) {
            .function_declaration, .function_expression, .function, .method_definition, .static_block => continue,
            .arrow_function_expression, .class_declaration, .class_expression, .for_statement, .for_in_statement, .for_of_statement, .while_statement, .do_while_statement => {
                if ((try @import("es2015_arrow.zig").ES2015Arrow(@TypeOf(self.*)).lexicalCaptures(self, index)).super_value) return true;
                if (node.tag == .class_declaration or node.tag == .class_expression) continue;
            },
            else => {},
        }
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    return false;
}

/// Type-only formal wrappers do not create a parameter initializer scope.
/// Keep runtime defaults, patterns and decorators on their existing paths.
pub fn simpleFormalBinding(self: anytype, index: ast.NodeIndex) ?ast.NodeIndex {
    const node = self.ast.getNode(index);
    if (node.tag == .binding_identifier) return index;
    if (node.tag != .formal_parameter or
        !self.ast.readExtraNode(node.data.extra, ast.FormalParameterExtra.default).isNone() or
        self.ast.readExtra(node.data.extra, ast.FormalParameterExtra.deco_len) != 0) return null;
    const pattern = self.ast.readExtraNode(node.data.extra, ast.FormalParameterExtra.pattern);
    if (pattern.isNone() or self.ast.getNode(pattern).tag != .binding_identifier) return null;
    return pattern;
}

pub fn prepareClass(self: anytype, class: ast.Node) !void {
    if (!self.semantic_edit_enabled or self.options.unsupported.class or !self.options.unsupported.arrow or
        self.options.experimental_decorators or self.options.plugins.len != 0 or self.plugins.worklet.auto_next) return;
    if (self.ast.readExtraNode(class.data.extra, ast.ClassExtra.super).isNone()) return;
    if (self.ast.readExtra(class.data.extra, ast.ClassExtra.deco_len) != 0) return;
    const body = self.ast.getNode(self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body));
    var constructor: ast.NodeIndex = .none;
    var first: ast.NodeIndex = .none;
    var native_private_method = false;
    const private = self.options.unsupported.privateLoweringPlan();
    for (0..body.data.list.len) |offset| {
        const index = self.ast.readExtraNode(body.data.list.start, @intCast(offset));
        const member = self.ast.getNode(index);
        if (member.tag == .accessor_property) return;
        if (member.tag == .method_definition) {
            if (self.ast.readExtra(member.data.extra, ast.MethodExtra.deco_len) != 0) return;
            if (private.methods and self.ast.getNode(self.ast.readExtraNode(member.data.extra, ast.MethodExtra.key)).tag == .private_identifier) return;
            if (helpers.isClassConstructorMethod(self, index, member)) constructor = index;
            const flags = self.ast.readExtra(member.data.extra, ast.MethodExtra.flags);
            if (!private.methods and flags & ast.MethodFlags.is_static == 0 and self.ast.getNode(self.ast.readExtraNode(member.data.extra, ast.MethodExtra.key)).tag == .private_identifier)
                native_private_method = true;
        } else if (member.tag == .property_definition) {
            if (self.ast.readExtra(member.data.extra, ast.PropertyExtra.deco_len) != 0) return;
            if (private.fields and self.ast.getNode(self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.key)).tag == .private_identifier) return;
            const flags = self.ast.readExtra(member.data.extra, ast.PropertyExtra.flags);
            if (flags & (ast.PropertyFlags.is_static | ast.PropertyFlags.is_abstract | ast.PropertyFlags.is_declare | ast.PropertyFlags.flow_variance) != 0) continue;
            // A target capability alone does not move public fields when the
            // class contains no private member requiring that lowering path.
            if (first.isNone() and !@import("native_parameter_cells.zig").instanceMemberMoves(self, member, false, !self.options.use_define_for_class_fields)) first = index;
        }
    }
    if (constructor.isNone() or (first.isNone() and !native_private_method)) return;
    const method = self.ast.getNode(constructor);
    const scope = self.outputOwnedScope(constructor) orelse return;
    const parameters = self.ast.readExtraNode(method.data.extra, ast.MethodExtra.params);
    if (!parameters.isNone()) {
        const list = self.ast.getNode(parameters).data.list;
        for (0..list.len) |offset| if (simpleFormalBinding(self, self.ast.readExtraNode(list.start, @intCast(offset))) == null) return;
    }
    if (!try @import("native_derived_this.zig").needsCellInScope(self, constructor, method, scope, true)) return;
    if (try hasDeferredSuper(self, self.ast.readExtraNode(method.data.extra, ast.MethodExtra.body))) return;
    var named = false;
    if (!first.isNone()) {
        const field = self.ast.getNode(first);
        named = anonymousValue(self, self.ast.readExtraNode(field.data.extra, ast.PropertyExtra.init));
        const key = self.ast.readExtraNode(field.data.extra, ast.PropertyExtra.key);
        // Runtime names need the class-key producer's per-evaluation cell.
        if (named and self.ast.getNode(key).tag == .computed_property_key and @import("retained_class_keys.zig").cellFor(self, key) == null) return;
    }
    try self.native_constructor_timing_plans.put(self.allocator, @backingInt(scope), .{ .first_field = first, .named_value = named });
    if (!first.isNone()) try self.native_constructor_timing_fields.put(self.allocator, @backingInt(first), @backingInt(scope));
}

pub fn fieldValue(self: anytype, source: ast.NodeIndex, key: ast.NodeIndex, value: ast.NodeIndex, key_identity: ?helpers.TempIdentityCapture, span: @import("../lexer/token.zig").Span) !ast.NodeIndex {
    const owner = self.native_constructor_timing_fields.get(@backingInt(source)) orelse return value;
    const plan = self.native_constructor_timing_plans.get(owner) orelse @panic("native field lost its constructor timing producer");
    var result = value;
    if (plan.named_value) {
        const property_key = if (key_identity) |identity| blk: {
            var use = identity;
            use.reference_scope = self.current_scope;
            const ref = try helpers.makeTempRefFromIdentity(self, use, span, .{ .read = true });
            try guard.recordReference(self, ref, identity.symbol_id.?, self.current_scope, .{ .read = true });
            break :blk ref;
        } else try helpers.buildDefinePropertyKeyArg(self, key);
        const computed = try self.ast.addNode(.{ .tag = .computed_property_key, .span = span, .data = .{ .unary = .{ .operand = property_key, .flags = 0 } } });
        const property = try self.ast.addNode(.{ .tag = .object_property, .span = span, .data = .{ .binary = .{ .left = computed, .right = result, .flags = 0 } } });
        const object = try self.ast.addNode(.{ .tag = .object_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{property}) } });
        const read_key = if (key_identity) |identity| blk: {
            var use = identity;
            use.reference_scope = self.current_scope;
            const ref = try helpers.makeTempRefFromIdentity(self, use, span, .{ .read = true });
            try guard.recordReference(self, ref, identity.symbol_id.?, self.current_scope, .{ .read = true });
            break :blk ref;
        } else try helpers.buildDefinePropertyKeyArg(self, key);
        result = try helpers.makeComputedMember(self, object, read_key, span);
    }
    if (result.isNone()) result = try helpers.makeVoidZero(self, span);
    const publish_receiver = try guard.publish(self, self.current_scope, span);
    return self.ast.addNode(.{ .tag = .sequence_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ publish_receiver, result }) } });
}
