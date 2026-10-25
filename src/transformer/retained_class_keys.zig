//! Per-evaluation lexical cells for retained native field names.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const helpers = @import("es_helpers.zig");
const Span = @import("../lexer/token.zig").Span;

pub const Cell = struct {
    key: ast.NodeIndex,
    arrow: ast.NodeIndex,
    capture: helpers.TempIdentityCapture,
};
pub const Plan = struct {
    source: ast.NodeIndex,
    cells: []Cell,
};

fn directArrow(self: anytype, value: ast.NodeIndex) ?ast.NodeIndex {
    var idx = value;
    while (!idx.isNone()) {
        const node = self.ast.getNode(idx);
        if (node.tag == .arrow_function_expression) return idx;
        if (node.tag != .parenthesized_expression) return null;
        idx = node.data.unary.operand;
    }
    return null;
}

/// Prove that this source site is not repeated in its enclosing activation.
/// A loop/with/function/class boundary requires per-evaluation storage instead.
fn singleEvaluationOwner(self: anytype, source: ast.NodeIndex, parent: @import("../semantic/scope.zig").ScopeId) !?@import("../semantic/scope.zig").ScopeId {
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var owner_scope = parent;
    while (!owner_scope.isNone()) {
        switch (scopes[owner_scope.toIndex()].kind) {
            .function, .module => break,
            .block, .switch_block, .catch_clause => owner_scope = scopes[owner_scope.toIndex()].parent,
            else => return null,
        }
    }
    if (owner_scope.isNone()) return null;
    const source_origin = self.scope_owner_origins.get(@backingInt(source)) orelse @backingInt(source);
    var owners = self.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(owner_scope)) continue;
        const owner_idx: ast.NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const owner = self.ast.getNode(owner_idx);
        const body_idx = switch (owner.tag) {
            .function_declaration, .function_expression, .method_definition => self.ast.readExtraNode(owner.data.extra, 2),
            .arrow_function_expression => self.ast.readExtraNode(owner.data.extra, 1),
            .program => owner_idx,
            else => continue,
        };
        if (body_idx.isNone()) continue;
        var stack: std.ArrayList(ast.NodeIndex) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, body_idx);
        while (stack.pop()) |idx| {
            if (idx.isNone()) continue;
            if (@backingInt(idx) == source_origin) return owner_scope;
            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement, .while_statement, .do_while_statement, .with_statement, .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => continue,
                else => {},
            }
            var children = @import("../parser/ast_walk.zig").children(self.ast, node);
            while (children.next()) |child| try stack.append(self.allocator, child);
        }
    }
    return null;
}

fn reserveHoistedCell(self: anytype, anchor: Span, owner: @import("../semantic/scope.zig").ScopeId) !helpers.TempIdentityCapture {
    const name = try helpers.makeTempVarSpan(self);
    const counter = self.temp_var_counter - 1;
    const producer = self.temp_producer_id_by_counter.get(counter) orelse @panic("field key has no temp producer");
    const id = (try self.reserveSyntheticTempSymbolForProducerInScope(producer, name, anchor, owner)) orelse @panic("field key has no exact temp SID");
    try self.temp_symbol_ids_by_counter.put(self.allocator, counter, @backingInt(id));
    return .{ .span = name, .symbol_id = id, .owner_scope = owner, .temp_producer_id = producer };
}

pub fn maybeWrap(self: anytype, source: ast.NodeIndex, original: ast.Node) !?ast.NodeIndex {
    if (!self.semantic_edit_enabled or !self.options.unsupported.arrow or self.options.unsupported.class or
        self.options.unsupported.class_field or !self.options.use_define_for_class_fields or self.options.experimental_decorators) return null;
    if (self.retained_class_key_plan) |plan| if (plan.source == source) return null;
    const body_idx = self.ast.readExtraNode(original.data.extra, ast.ClassExtra.body);
    if (body_idx.isNone()) return null;
    const body = self.ast.getNode(body_idx);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(self.allocator);
    const start = body.data.list.start;
    const len = body.data.list.len;
    for (0..len) |offset| {
        const member = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[start + offset])));
        if (member.tag != .property_definition) continue;
        const flags = self.readU32(member.data.extra, ast.PropertyExtra.flags);
        if (flags & 0xE0 != 0) continue;
        const key = self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.key);
        if (key.isNone() or self.ast.getNode(key).tag != .computed_property_key) continue;
        const arrow = directArrow(self, self.ast.readExtraNode(member.data.extra, ast.PropertyExtra.init)) orelse continue;
        const captures = try @import("es2015_arrow.zig").ES2015Arrow(@TypeOf(self.*)).lexicalCaptures(self, arrow);
        if (!captures.this_value and !captures.super_value) continue;
        try cells.append(self.allocator, .{ .key = key, .arrow = arrow, .capture = undefined });
    }
    if (cells.items.len == 0) return null;
    const class_scope = self.outputOwnedScope(source) orelse @panic("retained class key has no exact source scope");
    const parent = self.outputScopeParent(class_scope);
    const span = original.span;
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{}), span);
    const empty = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
    const wrapper_extra = try self.ast.addExtras(&.{ @backingInt(params), @backingInt(empty), 0 });
    const wrapper = try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = span, .data = .{ .extra = wrapper_extra } });
    const single_owner = try singleEvaluationOwner(self, source, parent);
    const single_evaluation = single_owner != null;
    const wrapper_scope = single_owner orelse try self.addGeneratedFunctionScope(parent, wrapper);
    if (!single_evaluation) {
        const editor = &self.semantic_editor.?;
        editor.scopes.items[wrapper_scope.toIndex()].subtree_has_direct_eval = editor.scopes.items[class_scope.toIndex()].subtree_has_direct_eval;
        editor.scopes.items[wrapper_scope.toIndex()].subtree_has_with = editor.scopes.items[class_scope.toIndex()].subtree_has_with;
        try self.reparentGeneratedScope(class_scope, wrapper_scope);
    }
    var statements: std.ArrayList(ast.NodeIndex) = .empty;
    defer statements.deinit(self.allocator);
    const declaration_anchor = Span{ .start = span.start, .end = span.start };
    var key_name_counter: u32 = 0;
    for (cells.items) |*cell| {
        if (single_owner) |actual_owner| {
            // The ordinary temp hoister emits this producer's exact binding
            // in its actual var owner, never in a surrounding argument list.
            cell.capture = try reserveHoistedCell(self, declaration_anchor, actual_owner);
            continue;
        }
        const output = helpers.ScopedSyntheticOutputName{
            .name = try self.buildUniqueNameAvoidingDynamicEval("_fieldKey", &key_name_counter, wrapper_scope),
            .late = helpers.canUseLateStandaloneOutputName(self, wrapper_scope) or helpers.canUseLateGraphOutputName(self, wrapper_scope),
        };
        const binding = try helpers.makeExactSyntheticBinding(self, output.name);
        const id = try self.declareSyntheticInScope(binding, declaration_anchor, if (single_evaluation) .variable_var else .variable_let, wrapper_scope);
        if (output.late) helpers.markStandaloneLateSyntheticTemp(self, id.?, wrapper_scope);
        cell.capture = .{ .span = self.ast.getNode(binding).data.string_ref, .symbol_id = id, .owner_scope = wrapper_scope };
        const declaration = try helpers.makeDeclarator(self, binding, .none, declaration_anchor);
        try statements.append(self.allocator, try helpers.makeVarDeclaration(self, &.{declaration}, if (single_evaluation) .@"var" else .let, declaration_anchor));
    }
    if (single_evaluation) {
        var plan = Plan{ .source = source, .cells = cells.items };
        const previous = self.retained_class_key_plan;
        self.retained_class_key_plan = &plan;
        defer self.retained_class_key_plan = previous;
        const value = try self.visitNode(source);
        return value;
    }
    const is_declaration = original.tag == .class_declaration;
    const outer_binding = self.ast.readExtraNode(original.data.extra, ast.ClassExtra.name);
    if (is_declaration and !outer_binding.isNone()) {
        // Keep the original outer binding and its SID on the lexical slot.
        // The class expression's inner binding owns the original class-self SID.
        const inner = try helpers.makeExactSyntheticBindingFromSpan(self, self.ast.getNode(outer_binding).data.string_ref);
        _ = try self.bindClassSelfStorage(source, inner, class_scope);
        self.ast.extra_data.items[original.data.extra + ast.ClassExtra.name] = @backingInt(inner);
    }
    self.ast.nodes.items[@backingInt(source)].tag = .class_expression;
    const ret = try self.ast.addNode(.{ .tag = .return_statement, .span = span, .data = .{ .unary = .{ .operand = source, .flags = 0 } } });
    try statements.append(self.allocator, ret);
    const wrapper_body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(statements.items) } });
    self.ast.extra_data.items[wrapper_extra + ast.ArrowExtra.body] = @backingInt(wrapper_body);
    var plan = Plan{ .source = source, .cells = cells.items };
    const previous = self.retained_class_key_plan;
    self.retained_class_key_plan = &plan;
    defer self.retained_class_key_plan = previous;
    var program_capture = try @import("retained_field_arrow.zig").prepareProgramWrapper(self, wrapper, span);
    const saved_capture = self.retained_field_this_plan;
    defer self.retained_field_this_plan = saved_capture;
    defer if (program_capture) |*capture| capture.deinit(self.allocator);
    if (program_capture) |*capture| self.retained_field_this_plan = capture;
    const called = try self.visitNode(try helpers.makeCallExpr(self, wrapper, &.{}, span));
    const value = if (program_capture) |*capture| try @import("retained_field_arrow.zig").finish(self, capture, called, span) else called;
    if (is_declaration and !outer_binding.isNone()) {
        const declaration = try helpers.makeDeclarator(self, outer_binding, value, span);
        return try helpers.makeVarDeclaration(self, &.{declaration}, .let, span);
    }
    return value;
}

pub fn cellFor(self: anytype, key: ast.NodeIndex) ?Cell {
    const plan = self.retained_class_key_plan orelse return null;
    for (plan.cells) |cell| if (cell.key == key) return cell;
    return null;
}

pub fn memoize(self: anytype, cell: Cell, visited: ast.NodeIndex, span: Span) !ast.NodeIndex {
    const key_value = self.ast.getNode(visited).data.unary.operand;
    var capture = cell.capture;
    capture.reference_scope = self.current_scope;
    const lhs = try helpers.makeTempRefFromIdentity(self, capture, span, .{ .write = true });
    const rhs = try helpers.makeToPropertyKey(self, key_value, span);
    const assignment = try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{ .left = lhs, .right = rhs, .flags = @backingInt(@import("../lexer/token.zig").Kind.eq) } } });
    return try self.ast.addNode(.{ .tag = .computed_property_key, .span = span, .data = .{ .unary = .{ .operand = assignment, .flags = 0 } } });
}
