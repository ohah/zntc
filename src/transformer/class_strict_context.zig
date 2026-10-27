//! Preserve the strict evaluation context of class code moved into a script.
//! Class headers can suspend and deliberately do not use this initializer API.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const es = @import("es_helpers.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

pub fn prependDirective(self: anytype, body_idx: NodeIndex) !void {
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) std.debug.panic("strict class context has no block body", .{});
    const list = body.data.list;
    if (list.len != 0) {
        const first = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[list.start])));
        if (first.tag == .directive and (std.mem.eql(u8, self.ast.getText(first.span), "\"use strict\"") or
            std.mem.eql(u8, self.ast.getText(first.span), "'use strict'"))) return;
    }
    const text = try self.ast.addString("\"use strict\"");
    const directive = try self.ast.addNode(.{ .tag = .directive, .span = text, .data = .{ .none = 0 } });
    const originals = try self.allocator.dupe(u32, self.ast.extra_data.items[list.start .. list.start + list.len]);
    defer self.allocator.free(originals);
    var statements: std.ArrayList(NodeIndex) = .empty;
    defer statements.deinit(self.allocator);
    try statements.append(self.allocator, directive);
    for (originals) |raw| try statements.append(self.allocator, @fromBackingInt(@intCast(raw)));
    self.ast.nodes.items[@backingInt(body_idx)].data.list = try self.ast.addNodeList(statements.items);
}

/// Named functions can have unowned name/parameter scopes between their
/// function owner and the source class. Transplant that entire lexical root,
/// keeping every existing ScopeId and its binding/reference identities.
pub fn moveInitializerScopes(self: anytype, root: NodeIndex, source: ScopeId, previous_output: ScopeId, target: ScopeId) !void {
    if (!self.semantic_edit_enabled) return;
    const editor = &self.semantic_editor.?;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        if (self.outputOwnedScope(idx)) |owned| {
            if (owned != source and owned != previous_output and owned != target) {
                var lexical_root = owned;
                var hops: usize = 0;
                while (!lexical_root.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
                    const parent = editor.scopes.items[lexical_root.toIndex()].parent;
                    if (parent == target) break;
                    if (parent == source or parent == previous_output) {
                        try self.reparentGeneratedScope(lexical_root, target);
                        break;
                    }
                    lexical_root = parent;
                }
            }
        }
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(idx));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
}

pub fn moveSourceReferences(self: anytype, root: NodeIndex, source: ScopeId, previous_output: ScopeId, target: ScopeId) !void {
    if (!self.semantic_edit_enabled) return;
    const editor = &self.semantic_editor.?;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        try self.relocateNodeScopeProvenance(idx, source, target);
        if (previous_output != source) try self.relocateNodeScopeProvenance(idx, previous_output, target);
        const existing = editor.referenceForNode(idx) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("strict initializer cannot inspect its source reference: {s}", .{@errorName(err)}),
        };
        if (existing) |reference| {
            if (!reference.flags.declare and (reference.scope_id == source or reference.scope_id == previous_output)) {
                const worklet_move = @import("worklet_class_clone.zig").prepareReferenceScopeMove(self, idx, reference, target) catch |err|
                    std.debug.panic("initializer lost its worklet creation identity: {s}", .{@errorName(err)});
                if (self.tracked_runtime_helper_ref_index.contains(@backingInt(idx))) {
                    try self.relocateRuntimeHelperRef(idx, target);
                } else editor.moveReference(idx, target, reference.stmt_idx, reference.scope_stmt_idx) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("strict initializer lost its exact source reference: {s}", .{@errorName(err)}),
                };
                if (worklet_move) |move| @import("worklet_class_clone.zig").completeReferenceScopeMove(self, move) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("initializer lost its worklet scope handoff: {s}", .{@errorName(err)}),
                };
            }
        }
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(idx));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
}

/// Field initializers cannot suspend in their own evaluation context. A strict
/// zero-parameter factory preserves both evaluation errors and strictness of
/// functions created by the initializer (including non-simple parameter lists).
pub fn visitInitializer(self: anytype, source: NodeIndex, class_scope: ScopeId, output_scope: ScopeId) !NodeIndex {
    // The ES5 class IIFE supplies strictness, but the initializer still moves
    // from the source class environment into that exact output function.
    if (self.options.unsupported.class) {
        if (self.semantic_edit_enabled) {
            try moveInitializerScopes(self, source, class_scope, output_scope, output_scope);
            try moveSourceReferences(self, source, class_scope, output_scope, output_scope);
        }
        const saved_scope = self.current_scope;
        self.current_scope = output_scope;
        defer self.current_scope = saved_scope;
        return self.visitNode(source);
    }
    const span = self.ast.getNode(source).span;
    const factory_scope = if (self.semantic_edit_enabled) try self.reserveGeneratedFunctionScope(output_scope) else output_scope;
    const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{}), span);
    const none = @backingInt(NodeIndex.none);
    const factory = try self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = try self.ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none }) },
    });
    if (self.semantic_edit_enabled) {
        try self.bindReservedFunctionOwner(factory_scope, factory);
        try moveInitializerScopes(self, source, class_scope, output_scope, factory_scope);
        try moveSourceReferences(self, source, class_scope, output_scope, factory_scope);
    }
    const saved_scope = self.current_scope;
    self.current_scope = factory_scope;
    defer self.current_scope = saved_scope;
    const pending_top = self.pending_nodes.items.len;
    defer self.pending_nodes.shrinkRetainingCapacity(pending_top);
    const trailing_top = self.trailing_nodes.items.len;
    defer self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
    const value = try self.visitNode(source);
    var statements: std.ArrayList(NodeIndex) = .empty;
    defer statements.deinit(self.allocator);
    try statements.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
    var result = value;
    if (self.trailing_nodes.items.len != trailing_top) {
        const name = try es.resolveScopedSyntheticOutputName(self, "_staticValue", factory_scope);
        const binding = try es.makeExactSyntheticBinding(self, name.name);
        const id = try self.declareSyntheticInScope(binding, span, .variable_var, factory_scope);
        try statements.append(self.allocator, try es.makeVarDeclaration(self, &.{try es.makeDeclarator(self, binding, value, span)}, .@"var", span));
        try statements.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
        result = try es.makeExactSyntheticRef(self, name.name);
        if (self.semantic_edit_enabled) {
            try self.addSyntheticRefInScope(result, id, factory_scope, .{ .read = true });
            try self.trackExactOutputReference(result, @backingInt(id.?));
        }
    }
    try statements.append(self.allocator, try self.ast.addNode(.{ .tag = .return_statement, .span = span, .data = .{ .unary = .{ .operand = result, .flags = 0 } } }));
    self.ast.nodes.items[@backingInt(body)].data.list = try self.ast.addNodeList(statements.items);
    try prependDirective(self, body);
    return es.makeCallExpr(self, factory, &.{}, span);
}
