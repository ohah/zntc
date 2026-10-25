//! Preserve a native non-simple parameter environment when ES2018 object rest
//! must move into the body. Raw native formals retain arity and unmapped
//! arguments; ordered lexical cells retain forward closures and genuine TDZ.
//! This producer covers statically nameable synchronous ordinary functions and
//! arrows. Class methods, async/generator timing and dynamic lookup retain
//! their existing lowering paths and remain separate follow-up boundaries.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const helpers = @import("es_helpers.zig");
const env = @import("parameter_environment.zig");
const NodeIndex = ast.NodeIndex;

pub fn applies(self: anytype, node: ast.Node) !bool {
    if (!self.semantic_edit_enabled or self.options.unsupported.default_params or self.options.unsupported.block_scoping or
        !self.options.unsupported.object_spread) return false;
    switch (node.tag) {
        .function, .function_expression, .function_declaration, .arrow_function_expression => {},
        else => return false,
    }
    const arrow = node.tag == .arrow_function_expression;
    const flags = self.ast.extra_data.items[node.data.extra + if (arrow) @as(u32, 2) else ast.FunctionExtra.flags];
    if (if (arrow) flags & ast.ArrowFlags.is_async != 0 else flags & (ast.FunctionFlags.is_async | ast.FunctionFlags.is_generator) != 0) return false;
    const params = self.ast.functionParamsList(node);
    if (!(try @import("es2015_params.zig").ES2015Params(@TypeOf(self.*)).hasObjectRestParam(self, params))) return false;
    if (try env.parameterListHasDynamicLookup(self, params)) return false;
    const body = self.ast.readExtraNode(node.data.extra, if (arrow) 1 else 2);
    if (try env.nodeHasDynamicLookup(self, body)) return false;
    return true;
}

pub fn normalize(self: anytype) !void {
    const count = self.ast.nodes.items.len;
    for (0..count) |raw| {
        const function = self.ast.nodes.items[raw];
        if (!(try applies(self, function))) continue;
        const owner: NodeIndex = @fromBackingInt(@intCast(raw));
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
        if (!non_simple) {
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
        self.ast.extra_data.items[body_slot] = @backingInt(try self.prependStatementsToBody(body, statements.items));
        const new_params = try self.ast.addFormalParameters(try self.ast.addNodeList(formals.items), self.ast.getNode(params_node).span);
        try self.remapCopiedScopeOwner(params_node, new_params);
        self.ast.extra_data.items[params_slot] = @backingInt(new_params);
    }
}
