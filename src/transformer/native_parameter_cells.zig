//! Preserve a native non-simple parameter environment when ES2018 object rest
//! must move into the body. Raw native formals retain arity and unmapped
//! arguments; ordered lexical cells retain forward closures and genuine TDZ.
//! Synchronous functions/arrows and actual class methods keep exact parameter
//! cells; constructors also move initialization behind lowered instance fields.
//! Dynamic environments, metadata/property formals and async/generator timing
//! retain their existing paths until their separate handoffs are available.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const helpers = @import("es_helpers.zig");
const env = @import("parameter_environment.zig");
const NodeIndex = ast.NodeIndex;

pub fn hasPotentialClassWork(self: anytype) bool {
    const unsupported = self.options.unsupported;
    return !unsupported.default_params and !unsupported.block_scoping and
        (unsupported.class_field or !self.options.use_define_for_class_fields or
            unsupported.requiresPrivateDownlevel());
}

fn classOwnerForMethod(self: anytype, owner: NodeIndex) ?NodeIndex {
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var scope = self.outputOwnedScope(owner) orelse return null;
    var remaining = scopes.len;
    while (!scope.isNone() and scope.toIndex() < scopes.len and remaining > 0) : (remaining -= 1) {
        if (scopes[scope.toIndex()].kind == .class_body) break;
        scope = scopes[scope.toIndex()].parent;
    }
    if (scope.isNone() or remaining == 0) return null;
    var owners = self.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(scope)) continue;
        const class_owner: NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const class = self.ast.getNode(class_owner);
        if (class.tag != .class_declaration and class.tag != .class_expression) continue;
        const body = self.ast.getNode(self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body));
        for (self.ast.extra_data.items[body.data.list.start .. body.data.list.start + body.data.list.len]) |member| {
            // Scope ancestry alone also admits an object method nested in a
            // field initializer. Only the actual class-member edge qualifies.
            if (member == @backingInt(owner)) return class_owner;
        }
    }
    return null;
}

fn classMovesNativePrivateInitializers(self: anytype, body: NodeIndex) bool {
    const unsupported = self.options.unsupported;
    if (self.options.use_define_for_class_fields and !unsupported.class_field) return false;
    // The assign/legacy producer can move an initializer while leaving its
    // private declaration and storage native. Match its actual entry path:
    // a private-only class may still take the native fast path when only
    // public class fields are marked unsupported.
    return !self.options.use_define_for_class_fields or self.options.experimental_decorators or
        (unsupported.class_field and @import("transformer/class_visit.zig").classBodyHasPublicField(self, body));
}

fn classMovesInstanceInitialization(self: anytype, class_owner: NodeIndex) bool {
    const class = self.ast.getNode(class_owner);
    const body_idx = self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body);
    const body = self.ast.getNode(body_idx);
    const private_fields_move = classLowersPrivateFields(self, body.data.list);
    const native_private_initializers_move = classMovesNativePrivateInitializers(self, body_idx);
    for (self.ast.extra_data.items[body.data.list.start .. body.data.list.start + body.data.list.len]) |raw| {
        if (instanceMemberMoves(self, self.ast.nodes.items[raw], private_fields_move, native_private_initializers_move)) return true;
    }
    return false;
}

pub fn instanceMemberMoves(self: anytype, member: ast.Node, private_fields_move: bool, native_private_initializers_move: bool) bool {
    const unsupported = self.options.unsupported;
    switch (member.tag) {
        .property_definition, .accessor_property, .method_definition => {},
        else => return false,
    }
    const flags = self.ast.readExtra(member.data.extra, if (member.tag == .method_definition) ast.MethodExtra.flags else ast.PropertyExtra.flags);
    if (flags & (ast.PropertyFlags.is_static | ast.PropertyFlags.is_abstract | ast.PropertyFlags.is_declare) != 0) return false;
    const key = self.ast.getNode(self.ast.readExtraNode(member.data.extra, 0));
    if (key.tag == .private_identifier) {
        if (member.tag == .method_definition) return unsupported.privateLoweringPlan().methods;
        return unsupported.privateLoweringPlan().fields or
            (native_private_initializers_move and !self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.init).isNone());
    }
    if (member.tag == .property_definition)
        return unsupported.class or unsupported.class_field or !self.options.use_define_for_class_fields or
            (private_fields_move and self.ast.readExtra(member.data.extra, ast.PropertyExtra.deco_len) == 0);
    return member.tag == .accessor_property and
        (unsupported.class or (unsupported.decorator_auto_accessor and
            (unsupported.privateLoweringPlan().fields or
                (native_private_initializers_move and !self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.init).isNone()))));
}

fn initializerObservesDynamicEnvironment(self: anytype, root: NodeIndex) !bool {
    const nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(nodes);
    for (nodes) |raw| {
        const node = self.ast.nodes.items[raw];
        if (node.tag == .with_statement) return true;
        if (!@import("static_class_capture.zig").isDirectEvalCall(self, node)) continue;
        if (self.ast.readExtra(node.data.extra, 2) == 0) continue;
        const args = self.ast.readExtra(node.data.extra, 1);
        const first = self.ast.getNode(self.ast.readExtraNode(args, 0));
        switch (first.tag) {
            .numeric_literal, .boolean_literal, .null_literal, .bigint_literal, .regexp_literal => continue,
            .string_literal => {},
            else => return true,
        }
        const decoded = @import("../string_escape.zig").decodeJsStringLiteral(self.allocator, self.ast.getText(first.span)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return true,
        };
        defer self.allocator.free(decoded);
        const text = std.mem.trim(u8, decoded, " \t\r\n");
        // Native class constructors retain strictness and the instance this.
        // Context-free arithmetic (including its syntax errors) sees neither
        // constructor bindings nor the erased class-field arguments context.
        if (std.mem.eql(u8, text, "this")) continue;
        for (text) |c| {
            if (std.mem.indexOfScalar(u8, "0123456789.+-*/%() \t\r\n", c) == null) return true;
        }
    }
    return false;
}

pub fn classLowersPrivateFields(self: anytype, members: ast.NodeList) bool {
    const unsupported = self.options.unsupported;
    if (!unsupported.privateLoweringPlan().fields) return false;
    for (self.ast.extra_data.items[members.start .. members.start + members.len]) |raw| {
        const member = self.ast.nodes.items[raw];
        if (member.tag != .property_definition and member.tag != .accessor_property) continue;
        const flags = self.ast.readExtra(member.data.extra, ast.PropertyExtra.flags);
        if (flags & (ast.PropertyFlags.is_abstract | ast.PropertyFlags.is_declare) != 0) continue;
        if (member.tag == .accessor_property and (unsupported.class or unsupported.decorator_auto_accessor)) return true;
        const key = self.ast.getNode(self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.key));
        if (key.tag == .private_identifier) return true;
    }
    return false;
}

pub fn applies(self: anytype, owner: NodeIndex) !bool {
    if (!self.semantic_edit_enabled or self.options.unsupported.default_params or self.options.unsupported.block_scoping or
        (!self.options.unsupported.object_spread and !hasPotentialClassWork(self))) return false;
    const node = self.ast.getNode(owner);
    switch (node.tag) {
        .function, .function_expression, .function_declaration, .arrow_function_expression, .method_definition => {},
        else => return false,
    }
    const arrow = node.tag == .arrow_function_expression;
    const source_flags = self.ast.extra_data.items[node.data.extra + if (arrow) @as(u32, 2) else ast.FunctionExtra.flags];
    const flags = if (node.tag == .method_definition) ast.methodFlagsToFunctionFlags(source_flags) else source_flags;
    if (if (arrow) flags & ast.ArrowFlags.is_async != 0 else flags & (ast.FunctionFlags.is_async | ast.FunctionFlags.is_generator) != 0) return false;
    const params = self.ast.functionParamsList(node);
    if (params.len == 0) return false;
    var moved_instance_initialization = false;
    if (node.tag == .method_definition) {
        const is_constructor = source_flags & ast.MethodFlags.is_static == 0 and
            helpers.isConstructorKey(self, self.ast.readExtraNode(node.data.extra, ast.MethodExtra.key));
        if (!self.options.unsupported.object_spread and !is_constructor) return false;
        const class_owner = classOwnerForMethod(self, owner) orelse return false;
        // These source formals are also metadata/property producers. Keep
        // their current path until the original-formal handoff is explicit.
        if (self.options.emit_decorator_metadata and
            (self.ast.readExtra(node.data.extra, ast.MethodExtra.deco_len) > 0 or
                (is_constructor and self.ast.readExtra(self.ast.getNode(class_owner).data.extra, ast.ClassExtra.deco_len) > 0))) return false;
        for (self.ast.extra_data.items[params.start .. params.start + params.len]) |raw| {
            const param = self.ast.nodes.items[raw];
            if (param.tag == .formal_parameter and
                (self.ast.readExtra(param.data.extra, ast.FormalParameterExtra.flags) != 0 or
                    self.ast.readExtra(param.data.extra, ast.FormalParameterExtra.deco_len) != 0)) return false;
        }
        moved_instance_initialization = is_constructor and classMovesInstanceInitialization(self, class_owner);
    }
    const Params = @import("es2015_params.zig").ES2015Params(@TypeOf(self.*));
    if (moved_instance_initialization) {
        if (!Params.hasDefaultOrRest(self, params)) return false;
    } else if (!self.options.unsupported.object_spread or !(try Params.hasObjectRestParam(self, params))) return false;
    if (try env.parameterListHasDynamicLookup(self, params)) return false;
    const body = self.ast.readExtraNode(node.data.extra, if (arrow) 1 else 2);
    if (body.isNone()) return false;
    if (moved_instance_initialization) {
        const class_owner = classOwnerForMethod(self, owner).?;
        const class = self.ast.getNode(class_owner);
        const class_body = self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body);
        const members = self.ast.getNode(class_body).data.list;
        const private_fields_move = classLowersPrivateFields(self, members);
        const native_private_initializers_move = classMovesNativePrivateInitializers(self, class_body);
        // Dynamic instance-initializer environments require their own source
        // class-context handoff, not constructor-local lexical bindings.
        for (self.ast.extra_data.items[members.start .. members.start + members.len]) |raw| {
            const member = self.ast.nodes.items[raw];
            if (member.tag != .property_definition and member.tag != .accessor_property) continue;
            if (!instanceMemberMoves(self, member, private_fields_move, native_private_initializers_move)) continue;
            if (try initializerObservesDynamicEnvironment(self, self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.init))) return false;
        }
    }
    if (try env.nodeHasDynamicLookup(self, body)) return false;
    return true;
}

pub fn normalize(self: anytype) !void {
    const count = self.ast.nodes.items.len;
    for (0..count) |raw| {
        const function = self.ast.nodes.items[raw];
        const owner: NodeIndex = @fromBackingInt(@intCast(raw));
        if (!(try applies(self, owner))) continue;
        const output_scope = self.outputOwnedScope(owner) orelse continue;
        const arrow = function.tag == .arrow_function_expression;
        const params_slot: u32 = function.data.extra + if (arrow) @as(u32, 0) else 1;
        const body_slot: u32 = function.data.extra + if (arrow) @as(u32, 1) else 2;
        const params_node: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[params_slot]));
        const parameter_scope = self.outputOwnedScope(params_node) orelse output_scope;
        const params = self.ast.functionParamsList(function);
        // AST appends can reallocate extra_data, so retain indices, never slices.
        var formals: std.ArrayList(NodeIndex) = .empty;
        defer formals.deinit(self.allocator);
        var statements: std.ArrayList(NodeIndex) = .empty;
        defer statements.deinit(self.allocator);
        const saved_scope = self.current_scope;
        defer self.current_scope = saved_scope;
        self.current_scope = output_scope;
        var non_simple = false;
        for (0..params.len) |i| {
            const source_param: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[params.start + i]));
            const param = self.ast.getNode(source_param);
            var pattern = source_param;
            var default: NodeIndex = .none;
            const rest = param.tag == .rest_element or param.tag == .spread_element;
            switch (param.tag) {
                .formal_parameter => {
                    pattern = self.ast.readExtraNode(param.data.extra, ast.FormalParameterExtra.pattern);
                    default = self.ast.readExtraNode(param.data.extra, ast.FormalParameterExtra.default);
                },
                .assignment_pattern => {
                    pattern = param.data.binary.left;
                    default = param.data.binary.right;
                },
                .rest_element, .spread_element => pattern = param.data.unary.operand,
                else => {},
            }
            const temp_name = try helpers.makeTempVarSpan(self);
            non_simple = non_simple or rest or !default.isNone();
            const binding = try helpers.makeSyntheticBinding(self, temp_name);
            const sid = (try self.declareSyntheticInScope(binding, param.span, .parameter, parameter_scope)) orelse
                std.debug.panic("native raw parameter has no creation identity", .{});
            helpers.consumeTempVarSpan(self, temp_name);
            self.forgetSyntheticTempSymbolLookup(temp_name, parameter_scope);
            const capture: helpers.TempIdentityCapture = .{ .span = temp_name, .symbol_id = sid, .reference_scope = output_scope };
            var formal = binding;
            if (rest) {
                formal = try self.ast.addNode(.{ .tag = .rest_element, .span = param.span, .data = .{ .unary = .{ .operand = binding, .flags = 0 } } });
            } else if (!default.isNone()) {
                formal = try self.ast.addNode(.{ .tag = .assignment_pattern, .span = param.span, .data = .{ .binary = .{ .left = binding, .right = try helpers.makeVoidZero(self, param.span), .flags = 0 } } });
            }
            try formals.append(self.allocator, formal);
            var value = try helpers.makeTempRefFromIdentity(self, capture, param.span, .{ .read = true });
            if (!default.isNone()) {
                const default_node = self.ast.getNode(default);
                const anonymous = switch (default_node.tag) {
                    .arrow_function_expression => true,
                    .function, .function_expression => self.ast.readExtraNode(default_node.data.extra, 0).isNone(),
                    .class_expression => self.ast.readExtraNode(default_node.data.extra, ast.ClassExtra.name).isNone(),
                    else => false,
                };
                if (anonymous and self.ast.getNode(pattern).tag == .binding_identifier) {
                    const id = self.getSymbolIdAt(pattern) orelse unreachable;
                    try self.parameter_inferred_names.put(self.allocator, @backingInt(default), self.semantic_editor.?.symbols.items[id].name);
                }
                const test_node = try self.ast.addNode(.{ .tag = .binary_expression, .span = param.span, .data = .{ .binary = .{ .left = value, .right = try helpers.makeVoidZero(self, param.span), .flags = @backingInt(@import("../lexer/token.zig").Kind.eq3) } } });
                value = try self.ast.addNode(.{ .tag = .conditional_expression, .span = param.span, .data = .{ .ternary = .{ .a = test_node, .b = default, .c = try helpers.makeTempRefFromIdentity(self, capture, param.span, .{ .read = true }) } } });
            }
            var bindings = try walk.bindingIdentifiers(self.allocator, self.ast, pattern, .{});
            defer bindings.deinit();
            while (try bindings.next()) |leaf| {
                const id = self.getSymbolIdAt(leaf) orelse std.debug.panic("native parameter cell lost source identity", .{});
                const alias = self.semantic_editor.?.symbols.items[id].synthetic_name;
                if (alias.len > 0 and !std.mem.eql(u8, alias, self.ast.identifierNameText(self.ast.getNode(leaf)))) {
                    // A shorthand key and binding can share the source node.
                    // Keep the property lookup spelling while publishing the
                    // already-selected alias on the exact binding edge.
                    const key_name = self.ast.getNode(leaf).data.string_ref;
                    const pattern_nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, pattern);
                    defer self.allocator.free(pattern_nodes);
                    for (pattern_nodes) |raw_node| {
                        const property = self.ast.nodes.items[raw_node];
                        if (property.tag != .binding_property or property.data.binary.left != leaf) continue;
                        const key = try helpers.makePropertyNameFromSpan(self, key_name);
                        self.ast.nodes.items[raw_node].data.binary.left = key;
                        if (property.data.binary.right.isNone()) self.ast.nodes.items[raw_node].data.binary.right = leaf;
                    }
                    const alias_span = try self.ast.addString(alias);
                    self.ast.nodes.items[@backingInt(leaf)].data.string_ref = alias_span;
                    // Generated-AST analyzer consumers still read binding.span
                    // as its identifier spelling. The source declaration span
                    // remains on the exact Symbol/declaration reference row.
                    self.ast.nodes.items[@backingInt(leaf)].span = alias_span;
                }
                // The source binding node is retained, including its exact
                // declaration anchor. Preserve the preflight-selected output
                // alias instead of selecting a name again from source text.
                self.semantic_editor.?.relocateSymbol(@fromBackingInt(id), output_scope) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("native parameter cell cannot retain its exact alias: {s}", .{@errorName(err)}),
                };
                self.semantic_editor.?.symbols.items[id].kind = .variable_let;
                self.semantic_editor.?.symbols.items[id].decl_flags = @import("../semantic/symbol.zig").SymbolKind.variable_let.declFlags();
            }
            try self.reparentGeneratedBodyScopes(parameter_scope, output_scope, source_param);
            try @import("class_strict_context.zig").moveSourceReferences(self, source_param, parameter_scope, parameter_scope, output_scope);
            const declaration = try helpers.makeVarDeclaration(self, &.{try helpers.makeDeclarator(self, pattern, value, param.span)}, .let, param.span);
            try self.ast.preserve_lexical_declaration_indices.append(self.allocator, @backingInt(declaration));
            try statements.append(self.allocator, declaration);
        }
        if (!non_simple and !self.semantic_editor.?.scopes.items[output_scope.toIndex()].is_strict) {
            // A native destructuring parameter also has unmapped arguments.
            // An unused rest tail preserves that property without changing
            // Function.length or reading another user argument.
            const name = try helpers.makeTempVarSpan(self);
            const binding = try helpers.makeSyntheticBinding(self, name);
            _ = (try self.declareSyntheticInScope(binding, function.span, .parameter, parameter_scope)) orelse
                std.debug.panic("unmapped-arguments tail has no creation identity", .{});
            helpers.consumeTempVarSpan(self, name);
            self.forgetSyntheticTempSymbolLookup(name, parameter_scope);
            try formals.append(self.allocator, try self.ast.addNode(.{ .tag = .rest_element, .span = function.span, .data = .{ .unary = .{ .operand = binding, .flags = 0 } } }));
        }
        try @import("transformer/driver.zig").appendParameterBodyVarCopies(self, output_scope, output_scope, &statements);
        var body: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[body_slot]));
        const body_node = self.ast.getNode(body);
        if (body_node.tag != .block_statement and body_node.tag != .function_body) {
            const ret = try self.ast.addNode(.{ .tag = .return_statement, .span = body_node.span, .data = .{ .unary = .{ .operand = body, .flags = 0 } } });
            body = try self.ast.addNode(.{ .tag = .block_statement, .span = body_node.span, .data = .{ .list = try self.ast.addNodeList(&.{ret}) } });
        }
        try publishBody(self, body_slot, body, statements.items);
        const new_params = try self.ast.addFormalParameters(try self.ast.addNodeList(formals.items), self.ast.getNode(params_node).span);
        try self.remapCopiedScopeOwner(params_node, new_params);
        self.ast.extra_data.items[params_slot] = @backingInt(new_params);
    }
}

pub fn publishBody(self: anytype, body_slot: u32, body: NodeIndex, statements: []const NodeIndex) !void {
    // The new body appends extra_data and can reallocate it. Resolve the
    // destination slot only after construction, never before the RHS.
    const initialized_body = try self.prependStatementsToBody(body, statements);
    self.ast.extra_data.items[body_slot] = @backingInt(initialized_body);
}
