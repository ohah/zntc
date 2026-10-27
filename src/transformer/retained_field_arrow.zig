//! Capture storage born at the actual retained-field arrow creation site.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const helpers = @import("es_helpers.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub const Plan = struct {
    source_this: std.AutoHashMapUnmanaged(u32, void),
    source_owner: ast.NodeIndex,
    wrapper: ast.NodeIndex,
    extra: u32,
    capture: helpers.TempIdentityCapture,
    has_super: bool,
    home_symbol: ?u32,
    static_home: bool,
    name_cell: ?@import("retained_class_keys.zig").Cell,
    name_capture: ?helpers.TempIdentityCapture,
    callsite_scope: ScopeId,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.source_this.deinit(allocator);
    }
};

fn collect(self: anytype, root: ast.NodeIndex, nodes: *std.AutoHashMapUnmanaged(u32, void), has_super: *bool) !void {
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const node = self.ast.getNode(idx);
        if (idx != root) switch (node.tag) {
            .function_declaration, .function_expression, .function, .static_block => continue,
            .method_definition, .property_definition, .accessor_property => {
                // Only keys/decorators evaluate in the surrounding environment.
                try stack.append(self.allocator, self.readNodeIdx(node.data.extra, 0));
                const deco_offset: u32 = if (node.tag == .method_definition) 4 else 3;
                const start = self.readU32(node.data.extra, deco_offset);
                const len = self.readU32(node.data.extra, deco_offset + 1);
                for (self.ast.extra_data.items[start .. start + len]) |raw|
                    try stack.append(self.allocator, @fromBackingInt(@intCast(raw)));
                continue;
            },
            else => {},
        };
        if (node.tag == .super_expression) has_super.* = true;
        if (node.tag == .this_expression) try nodes.put(self.allocator, @backingInt(idx), {});
        var children = @import("../parser/ast_walk.zig").children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
}

pub fn prepare(self: anytype, source_owner: ast.NodeIndex, span: @import("../lexer/token.zig").Span) !?Plan {
    if (self.retained_field_initializer_frame == 0 or
        self.capture_frame != self.retained_field_initializer_frame or
        self.retained_field_this_plan != null) return null;
    return prepareOwnedArrow(self, source_owner, span);
}

/// A program's lexical this is already initialized and immutable. Capture it
/// at this new wrapper's call site instead of inventing a program-body alias.
pub fn prepareProgramWrapper(self: anytype, source_owner: ast.NodeIndex, span: @import("../lexer/token.zig").Span) !?Plan {
    if (self.capture_frame != 0 or self.retained_field_this_plan != null) return null;
    const scope = self.outputOwnedScope(source_owner) orelse return null;
    const parent = self.outputScopeParent(scope);
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (parent.isNone() or (scopes[parent.toIndex()].kind != .global and scopes[parent.toIndex()].kind != .module)) return null;
    return prepareOwnedArrow(self, source_owner, span);
}

fn prepareOwnedArrow(self: anytype, source_owner: ast.NodeIndex, span: @import("../lexer/token.zig").Span) !?Plan {
    var nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    errdefer nodes.deinit(self.allocator);
    var has_super = false;
    try collect(self, source_owner, &nodes, &has_super);
    if (nodes.count() == 0 and !has_super) {
        nodes.deinit(self.allocator);
        return null;
    }
    const arrow_scope = if (self.semantic_edit_enabled)
        self.outputOwnedScope(source_owner) orelse @panic("retained field arrow has no exact source scope")
    else
        self.current_scope;
    const source = self.ast.getNode(source_owner);
    const params = self.ast.readExtraNode(source.data.extra, 0);
    const lexical_root = self.outputOwnedScope(params) orelse arrow_scope;
    const parent = if (self.semantic_edit_enabled) self.outputScopeParent(lexical_root) else self.current_scope;
    const output: helpers.ScopedSyntheticOutputName = if (self.semantic_edit_enabled)
        try helpers.resolveScopedSyntheticOutputNameWithGraph(self, "_this", arrow_scope)
    else
        .{ .name = try helpers.resolveSyntheticName(self, "_this"), .late = false };
    const binding = try helpers.makeExactSyntheticBinding(self, output.name);
    const name_cell = if (self.retained_field_name_cell) |cell| if (cell.arrow == source_owner) cell else null else null;
    const name_output = if (name_cell != null) try helpers.resolveScopedSyntheticOutputNameWithGraph(self, "_nameKey", arrow_scope) else null;
    const name_binding = if (name_output) |selected| try helpers.makeExactSyntheticBinding(self, selected.name) else ast.NodeIndex.none;
    const parameter_list = if (name_binding.isNone()) try self.ast.addNodeList(&.{binding}) else try self.ast.addNodeList(&.{ binding, name_binding });
    const parameters = try self.ast.addFormalParameters(parameter_list, span);
    const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
    const extra = try self.ast.addExtras(&.{ @backingInt(ast.NodeIndex.none), @backingInt(parameters), @backingInt(body), 0, @backingInt(ast.NodeIndex.none) });
    const wrapper = try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{ .extra = extra } });
    const scope = try self.addGeneratedFunctionScope(parent, wrapper);
    if (self.semantic_editor) |*editor| {
        editor.scopes.items[scope.toIndex()].subtree_has_direct_eval = editor.scopes.items[lexical_root.toIndex()].subtree_has_direct_eval;
        editor.scopes.items[scope.toIndex()].subtree_has_with = editor.scopes.items[lexical_root.toIndex()].subtree_has_with;
    }
    try self.reparentGeneratedScope(lexical_root, scope);
    const symbol = try self.declareSyntheticInScope(binding, span, .parameter, scope);
    const name_capture: ?helpers.TempIdentityCapture = if (name_binding.isNone()) null else .{
        .span = self.ast.getNode(name_binding).data.string_ref,
        .symbol_id = try self.declareSyntheticInScope(name_binding, span, .parameter, scope),
        .owner_scope = scope,
    };
    if (name_output) |selected| if (selected.late) helpers.markStandaloneLateSyntheticTemp(self, name_capture.?.symbol_id.?, scope);
    if (output.late) helpers.markScopedLateSyntheticSymbol(self, symbol orelse @panic("field capture has no SID"), arrow_scope, .this_capture_binding, "_this");
    return .{ .name_cell = name_cell, .name_capture = name_capture, .callsite_scope = parent, .has_super = has_super, .home_symbol = self.current_class_self_symbol_id, .static_home = self.retained_field_initializer_static, .source_owner = source_owner, .source_this = nodes, .wrapper = wrapper, .extra = extra, .capture = .{ .span = self.ast.getNode(binding).data.string_ref, .symbol_id = symbol, .owner_scope = scope } };
}

pub fn reference(self: anytype, source: ast.NodeIndex, span: @import("../lexer/token.zig").Span) !?ast.NodeIndex {
    const plan = self.retained_field_this_plan orelse return null;
    if (!plan.source_this.contains(@backingInt(source))) return null;
    var capture = plan.capture;
    capture.reference_scope = self.current_scope;
    return try helpers.makeTempRefFromIdentity(self, capture, span, .{ .read = true });
}

pub fn finish(self: anytype, plan: *const Plan, value: ast.NodeIndex, span: @import("../lexer/token.zig").Span) !ast.NodeIndex {
    try self.remapCopiedScopeOwner(plan.source_owner, value);
    var return_value = value;
    if (plan.name_capture) |name| {
        var capture = name;
        capture.reference_scope = name.owner_scope;
        const key = try helpers.makeTempRefFromIdentity(self, capture, span, .{ .read = true });
        const computed = try self.ast.addNode(.{ .tag = .computed_property_key, .span = span, .data = .{ .unary = .{ .operand = key, .flags = 0 } } });
        const property = try self.ast.addNode(.{ .tag = .object_property, .span = span, .data = .{ .binary = .{ .left = computed, .right = value, .flags = 0 } } });
        const object = try self.ast.addNode(.{ .tag = .object_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{property}) } });
        const read = try helpers.makeTempRefFromIdentity(self, capture, span, .{ .read = true });
        return_value = try helpers.makeComputedMember(self, object, read, span);
    }
    const ret = try self.ast.addNode(.{ .tag = .return_statement, .span = span, .data = .{ .unary = .{ .operand = return_value, .flags = 0 } } });
    const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ret}) } });
    self.ast.extra_data.items[plan.extra + 2] = @backingInt(body);
    const receiver = try self.ast.addNode(.{ .tag = .this_expression, .span = span, .data = .{ .none = 0 } });
    if (plan.name_cell) |cell| {
        var capture = cell.capture;
        capture.reference_scope = plan.callsite_scope;
        const key = try helpers.makeTempRefFromIdentity(self, capture, span, .{ .read = true });
        return helpers.makeCallExpr(self, plan.wrapper, &.{ receiver, key }, span);
    }
    return helpers.makeCallExpr(self, plan.wrapper, &.{receiver}, span);
}

pub fn activeSuper(self: anytype) bool {
    const plan = self.retained_field_this_plan orelse return false;
    return self.semantic_edit_enabled and plan.has_super and plan.home_symbol != null and
        plan.home_symbol == self.current_class_self_symbol_id and self.current_super_home_object == null;
}

pub fn superReceiver(self: anytype, span: @import("../lexer/token.zig").Span) !?ast.NodeIndex {
    if (!activeSuper(self)) return null;
    var capture = self.retained_field_this_plan.?.capture;
    capture.reference_scope = self.current_scope;
    return try helpers.makeTempRefFromIdentity(self, capture, span, .{ .read = true });
}

pub fn superBase(self: anytype, span: @import("../lexer/token.zig").Span) !?ast.NodeIndex {
    if (!activeSuper(self)) return null;
    const plan = self.retained_field_this_plan.?;
    const id = plan.home_symbol.?;
    const name = self.semantic_editor.?.symbols.items[id].name;
    var home = try helpers.makeIdentifierRefFromSpan(self, name);
    try self.addSyntheticRefInScope(home, @fromBackingInt(@intCast(id)), self.current_scope, .{ .read = true });
    if (!plan.static_home) home = try helpers.makeStaticMember(self, home, try helpers.makePropertyName(self, "prototype"), span);
    const global = try helpers.makeGlobalRef(self, "globalThis");
    const object = try helpers.makeStaticMember(self, global, try helpers.makePropertyName(self, "Object"), span);
    const get_proto = try helpers.makeStaticMember(self, object, try helpers.makePropertyName(self, "getPrototypeOf"), span);
    return try helpers.makeCallExpr(self, get_proto, &.{home}, span);
}
