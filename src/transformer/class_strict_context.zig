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
    return moveSourceReferencesIntoFactory(self, root, source, previous_output, target, null);
}

const Factory = struct { owner: NodeIndex, parameters: NodeIndex, body: NodeIndex, epoch: u32 };
pub const PendingInitializer = struct { node: NodeIndex, source_node: NodeIndex, source_index: u32, from: ScopeId, to: ScopeId, move_index: usize };

fn carryDynamicEffects(self: anytype, source: ScopeId, target: ScopeId) !void {
    const editor = &self.semantic_editor.?;
    const original = editor.scopes.items[source.toIndex()];
    var completed = editor.scopes.items[target.toIndex()];
    completed.subtree_has_direct_eval = completed.subtree_has_direct_eval or original.subtree_has_direct_eval;
    completed.subtree_has_with = completed.subtree_has_with or original.subtree_has_with;
    editor.scope_history.recordOwnedFrame(self.allocator, self.ast, editor.scopes.items, &editor.scope_owner_map, target, completed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("strict initializer lost its actual dynamic frame"),
    };
    editor.scopes.items[target.toIndex()] = completed;
}

pub fn moveStaticFieldReferences(self: anytype, root: NodeIndex, source: ScopeId, target: ScopeId) !void {
    if (!self.semantic_edit_enabled or root.isNone()) return;
    try carryDynamicEffects(self, source, target);
    try moveSourceReferencesIntoFactory(self, root, source, source, target, .{ .owner = .none, .parameters = .none, .body = .none, .epoch = 0 });
}

/// A class IIFE reserves its real frame before visiting fields, but publishes
/// the actual function owner only after its complete body exists.
pub fn completeReservedOwner(self: anytype, scope: ScopeId, owner: NodeIndex) !void {
    if (!self.semantic_edit_enabled or self.pending_static_initializer_transfers.items.len == 0) return;
    const editor = &self.semantic_editor.?;
    var index: usize = 0;
    while (index < self.pending_static_initializer_transfers.items.len) {
        const pending = self.pending_static_initializer_transfers.items[index];
        if (pending.to != scope) {
            index += 1;
            continue;
        }
        var entry = editor.node_scope_provenance.get(pending.node) orelse @panic("class initializer lost its pending exact source carrier");
        var origin = entry.source_external orelse @panic("class initializer lost its pending unresolved origin");
        if (pending.move_index >= origin.scope_moves.len) @panic("class initializer lost its pending move");
        const moves = try self.allocator.dupe(@import("../semantic/source_external_origin.zig").ScopeMove, origin.scope_moves);
        const move = &moves[pending.move_index];
        if (move.reason != .lowerer_scope_relocation or move.node != pending.node or move.source_node != pending.source_node or move.from != pending.from or move.to != pending.to)
            @panic("class initializer pending move changed its actual producer");
        const function = self.ast.getNode(owner);
        if (function.tag != .function_expression) @panic("class initializer has no actual class IIFE owner");
        move.reason = .class_initializer_environment_transfer;
        move.class_initializer = .{ .source_index = pending.source_index, .target_owner = (@import("../semantic/scope_frame_history.zig").Owner.capture(self.ast, owner) catch @panic("class IIFE has an invalid actual owner")).?, .parameters = self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params), .body = self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.body), .owner_epoch = editor.scope_history.epoch() };
        origin.scope_moves = moves;
        entry.source_external = origin;
        try editor.node_scope_provenance.put(self.allocator, pending.node, entry);
        try self.transformed_node_scope_provenance.put(self.allocator, pending.node, entry);
        self.node_scope_provenance_changed = true;
        _ = self.pending_static_initializer_transfers.orderedRemove(index);
    }
}

fn moveSourceReferencesIntoFactory(self: anytype, root: NodeIndex, source: ScopeId, previous_output: ScopeId, target: ScopeId, factory: ?Factory) !void {
    if (!self.semantic_edit_enabled) return;
    const editor = &self.semantic_editor.?;
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        var transferred = false;
        if (factory) |actual| if (editor.node_scope_provenance.get(idx)) |previous| {
            if (previous.scope == source) if (previous.source_external) |origin| {
                if (origin.execution_scope == source) {
                    var known: ?u32 = null;
                    for (editor.scope_history.source_initializers, 0..) |entry, index| {
                        if (entry.scope != source or entry.initializer.node != root or entry.leaf.node != previous.source_node) continue;
                        if (known != null) @panic("static initializer has duplicate original source carriers");
                        known = @intCast(index);
                    }
                    const source_index = known orelse @panic("static initializer lost its original field carrier");
                    var moved = previous;
                    moved.scope = target;
                    const External = @import("../semantic/source_external_origin.zig");
                    if (actual.owner.isNone()) {
                        moved.source_external = try External.moved(self.allocator, origin, idx, previous.source_node, source, target, editor.scopes.items, editor.scope_history.epoch());
                        try self.pending_static_initializer_transfers.append(self.allocator, .{ .node = idx, .source_node = previous.source_node, .source_index = source_index, .from = source, .to = target, .move_index = moved.source_external.?.scope_moves.len - 1 });
                    } else moved.source_external = try External.transferredClassInitializer(self.allocator, origin, idx, previous.source_node, source, target, editor.scopes.items, editor.scope_history.epoch(), .{
                        .source_index = source_index,
                        .target_owner = (@import("../semantic/scope_frame_history.zig").Owner.capture(self.ast, actual.owner) catch @panic("strict initializer factory has an invalid actual owner")).?,
                        .parameters = actual.parameters,
                        .body = actual.body,
                        .owner_epoch = actual.epoch,
                    });
                    try editor.node_scope_provenance.put(self.allocator, idx, moved);
                    try self.transformed_node_scope_provenance.put(self.allocator, idx, moved);
                    self.node_scope_provenance_changed = true;
                    transferred = true;
                }
            };
        };
        if (!transferred) try self.relocateNodeScopeProvenance(idx, source, target);
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
            try moveStaticFieldReferences(self, source, class_scope, output_scope);
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
        const owner_epoch = self.semantic_editor.?.scope_history.epoch();
        try carryDynamicEffects(self, class_scope, factory_scope);
        try moveInitializerScopes(self, source, class_scope, output_scope, factory_scope);
        try moveSourceReferencesIntoFactory(self, source, class_scope, output_scope, factory_scope, .{ .owner = factory, .parameters = params, .body = body, .epoch = owner_epoch });
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
