//! Worklet class-clone publication. Identity comes from the actual clone
//! creator; current AST lists supply statement coordinates only.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const symbol = @import("../semantic/symbol.zig");
const state = @import("plugin_state.zig");
const projection = @import("../bundler/statement_owner_projection.zig");

pub fn register(self: anytype, factory: state.WorkletClassFactory, cloned: anytype, self_binding: ast.NodeIndex) !void {
    if (factory.ast_owner != self.ast or self.outputOwnedScope(factory.source_class) != factory.source_scope or
        self.outputOwnedScope(factory.target_class) != factory.target_scope or
        self.class_self_symbol_map.get(@backingInt(factory.source_class)) != @backingInt(factory.source_self) or
        self.class_self_symbol_map.get(@backingInt(factory.target_class)) != @backingInt(factory.target_self))
        @panic("worklet clone registration lost its exact class creator");
    const index = self.plugins.worklet.class_factories.items.len;
    try self.plugins.worklet.class_factories.append(self.allocator, factory);
    try registerReferences(self, index, cloned, self_binding);
}

fn registerReferences(self: anytype, index: usize, cloned: anytype, self_binding: ast.NodeIndex) !void {
    const editor = &self.semantic_editor.?;
    var nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer nodes.deinit(self.allocator);
    var values = cloned.nodes.valueIterator();
    while (values.next()) |node| try nodes.put(self.allocator, @backingInt(node.*), {});
    if (!self_binding.isNone()) try nodes.put(self.allocator, @backingInt(self_binding), {});
    for (editor.references.items) |reference| {
        const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        if (node.isNone() or !nodes.contains(@backingInt(node))) continue;
        const entry = try self.plugins.worklet.class_reference_origins.getOrPut(self.allocator, @backingInt(node));
        if (entry.found_existing) @panic("worklet clone has a duplicate creation reference");
        entry.value_ptr.* = .{ .factory = index, .symbol = reference.symbol_id, .scope = reference.scope_id, .flags = reference.flags };
        try self.plugins.worklet.class_reference_nodes.append(self.allocator, node);
    }
}

/// A preserved accessor copies a second live function environment. Its
/// source references already identify the enclosing class factory, if any.
pub fn registerMethod(self: anytype, cloned: anytype) !void {
    var factory: ?usize = null;
    var originals = cloned.nodes.keyIterator();
    while (originals.next()) |raw| {
        const origin = self.plugins.worklet.class_reference_origins.get(raw.*) orelse continue;
        if (factory) |previous| {
            if (previous != origin.factory) @panic("worklet method copy spans foreign factories");
        }
        factory = origin.factory;
    }
    if (factory) |index| try registerReferences(self, index, cloned, .none);
}

/// Validate all participants before publishing any row. No SID, Scope, flags
/// or missing declaration identity is selected by statement containment.
pub fn publishChecked(self: anytype, root: ast.NodeIndex) !void {
    if (!self.semantic_edit_enabled or self.plugins.worklet.class_factories.items.len == 0) return;
    const editor = &self.semantic_editor.?;
    const contexts = try projection.collect(self.allocator, self.ast, root);
    defer self.allocator.free(contexts);
    for (self.plugins.worklet.class_factories.items) |factory| {
        if (self.scope_owner_map.get(@backingInt(factory.source_class)) != @backingInt(factory.source_scope) or
            editor.scope_owner_map.get(@backingInt(factory.target_class)) != @backingInt(factory.target_scope) or
            self.class_self_symbol_map.get(@backingInt(factory.source_class)) != @backingInt(factory.source_self) or
            self.class_self_symbol_map.get(@backingInt(factory.target_class)) != @backingInt(factory.target_self))
            return error.InvalidWorkletFactoryOwner;
        if (factory.ast_owner != self.ast or factory.scope.isNone() or factory.parent.isNone() or factory.scope.toIndex() >= editor.scopes.items.len or
            editor.scopes.items[factory.scope.toIndex()].kind != .function or editor.scopes.items[factory.scope.toIndex()].parent != factory.parent or
            @backingInt(factory.binding) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(factory.binding)] != @backingInt(factory.symbol))
            return error.InvalidWorkletFactoryOwner;
        var live_owners: usize = 0;
        for (self.ast.nodes.items, 0..) |node, raw| {
            if (raw >= contexts.len or contexts[raw] == null) continue;
            if (node.tag != .function_declaration and node.tag != .function_expression) continue;
            const owner = self.outputOwnedScope(@fromBackingInt(@as(u32, @intCast(raw)))) orelse continue;
            if (owner != factory.scope) continue;
            const binding = self.ast.readExtraNode(node.data.extra, ast.FunctionExtra.name);
            if (binding != factory.binding) return error.InvalidWorkletFactoryOwner;
            live_owners += 1;
        }
        if (live_owners != 1) return error.InvalidWorkletFactoryOwner;
    }
    var current_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer current_owners.deinit(self.allocator);
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const scopes = try self.allocator.alloc(?ScopeId, self.ast.nodes.items.len);
    defer self.allocator.free(scopes);
    @memset(scopes, null);
    const Work = struct { node: ast.NodeIndex, scope: ScopeId };
    var pending: std.ArrayList(Work) = .empty;
    defer pending.deinit(self.allocator);
    try pending.append(self.allocator, .{ .node = root, .scope = self.programScope() });
    while (pending.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        if (raw >= scopes.len) return error.InvalidWorkletCloneOrigin;
        const own_scope = self.outputOwnedScope(work.node);
        if (own_scope) |owner| try current_owners.put(self.allocator, raw, @backingInt(owner));
        const scope = own_scope orelse work.scope;
        if (scopes[raw]) |seen| {
            if (seen != scope) return error.InvalidWorkletCloneOrigin;
            continue;
        }
        scopes[raw] = scope;
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(work.node));
        while (children.next()) |child| {
            const child_scope = if (@import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, raw, @backingInt(child))) work.scope else scope;
            try pending.append(self.allocator, .{ .node = child, .scope = child_scope });
        }
    }
    for (self.plugins.worklet.class_reference_nodes.items) |node| {
        const raw = @backingInt(node);
        const origin = self.plugins.worklet.class_reference_origins.get(raw) orelse return error.MissingWorkletCloneOrigin;
        if (origin.factory >= self.plugins.worklet.class_factories.items.len or raw >= contexts.len) return error.InvalidWorkletCloneOrigin;
        if (contexts[raw] == null) continue; // A later exact producer may replace the cloned source expression.
        if (raw >= editor.symbol_ids.items.len or editor.symbol_ids.items[raw] != @backingInt(origin.symbol)) return error.InvalidWorkletCloneOrigin;
        if (@backingInt(origin.symbol) >= editor.symbols.items.len or origin.scope.isNone() or origin.scope.toIndex() >= editor.scopes.items.len)
            return error.InvalidWorkletCloneOrigin;
        if (origin.flags.declare) {
            if (editor.symbols.items[@backingInt(origin.symbol)].scope_id != origin.scope) return error.InvalidWorkletCloneOrigin;
        } else if (scopes[raw] != origin.scope) {
            std.debug.print("worklet clone scope drift node={d} name={s} SID={d} birth={d} actual={any} classUnsupported={any}\n", .{ raw, self.ast.identifierNameText(self.ast.getNode(node)), @backingInt(origin.symbol), @backingInt(origin.scope), scopes[raw], self.options.unsupported.class });
            return error.InvalidWorkletCloneOrigin;
        }
        var enclosing = origin.scope;
        var hops: usize = 0;
        const factory_scope = self.plugins.worklet.class_factories.items[origin.factory].scope;
        while (enclosing != factory_scope) : (hops += 1) {
            if (enclosing.isNone() or enclosing.toIndex() >= editor.scopes.items.len or hops >= editor.scopes.items.len)
                return error.InvalidWorkletCloneOrigin;
            enclosing = editor.scopes.items[enclosing.toIndex()].parent;
        }
        var count: usize = 0;
        for (editor.references.items) |reference| {
            const anchor = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
            if (anchor != node) continue;
            if (reference.symbol_id != origin.symbol or reference.scope_id != origin.scope or !std.meta.eql(reference.flags, origin.flags))
                return error.InvalidWorkletCloneOrigin;
            count += 1;
        }
        if (count != 1) return error.InvalidWorkletCloneOrigin;
    }
    // Actual factory insertion can shift coordinates of unrelated existing
    // rows too. This is positions-only reindexing, not clone authority.
    var selected: std.ArrayList(symbol.Reference) = .empty;
    defer selected.deinit(self.allocator);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(self.allocator);
    var classes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer classes.deinit(self.allocator);
    var selves = self.class_self_symbol_map.valueIterator();
    while (selves.next()) |id| try classes.put(self.allocator, id.*, {});
    for (editor.references.items, 0..) |reference, index| {
        const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        const live = !node.isNone() and @backingInt(node) < contexts.len and contexts[@backingInt(node)] != null;
        const id = @backingInt(reference.symbol_id);
        const anchorless_role = reference.flags.declare and node.isNone() and id < editor.symbols.items.len and
            (classes.contains(id) or editor.symbols.items[id].decl_flags.is_default_export);
        if (!live and !anchorless_role) continue;
        try selected.append(self.allocator, reference);
        try indices.append(self.allocator, index);
    }
    const view = .{ .references = selected.items, .symbols = editor.symbols, .scopes = editor.scopes.items, .symbol_ids = editor.symbol_ids.items, .scope_owner_map = current_owners, .class_self_symbol_map = self.class_self_symbol_map };
    const updated = (try projection.project(self.allocator, self.ast, root, &view)) orelse return error.InvalidWorkletStatementOwner;
    defer self.allocator.free(updated);
    for (updated, indices.items) |reference, index| {
        editor.references.items[index].stmt_idx = reference.stmt_idx;
        editor.references.items[index].scope_stmt_idx = reference.scope_stmt_idx;
    }
}

pub fn publish(self: anytype, root: ast.NodeIndex) std.mem.Allocator.Error!void {
    publishChecked(self, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("worklet clone publication rejected: {s}", .{@errorName(err)}),
    };
}

/// A class-self reader/writer creator replaces an existing cloned source
/// read with a fresh immutable-capture use. This is a new identity/Scope, not
/// an ordinary copy that may inherit its source's planned Scope.
pub fn registerClassSelfReplacement(self: anytype, source: ast.NodeIndex, replacement: ast.NodeIndex, reference: symbol.Reference) !void {
    const source_origin = self.plugins.worklet.class_reference_origins.get(@backingInt(source)) orelse return;
    const own = self.static_class_reference_origins.get(@backingInt(replacement)) orelse @panic("worklet replacement has no actual capture creator");
    if (own.source != source or own.source_symbol_id != @backingInt(source_origin.symbol) or
        reference.node_index != replacement or reference.symbol_id == source_origin.symbol or reference.scope_id != self.current_scope or
        !std.meta.eql(reference.flags, source_origin.flags) or source_origin.factory >= self.plugins.worklet.class_factories.items.len or
        self.plugins.worklet.class_factories.items[source_origin.factory].ast_owner != self.ast or
        !@import("static_class_capture.zig").validOwnReferenceOrigin(self, replacement))
        @panic("worklet replacement changed its exact source capture contract");
    const entry = try self.plugins.worklet.class_reference_origins.getOrPut(self.allocator, @backingInt(replacement));
    if (entry.found_existing) @panic("worklet replacement was registered twice");
    entry.value_ptr.* = .{ .factory = source_origin.factory, .symbol = reference.symbol_id, .scope = reference.scope_id, .flags = reference.flags };
    try self.plugins.worklet.class_reference_nodes.append(self.allocator, replacement);
    try self.plugins.worklet.class_reference_replacements.put(self.allocator, @backingInt(replacement), source);
    try self.trackExactOutputReferenceInScope(replacement, @backingInt(reference.symbol_id), reference.scope_id);
}

pub fn isClassSelfReplacement(self: anytype, source: ast.NodeIndex, replacement: ast.NodeIndex) bool {
    const raw = @backingInt(replacement);
    if (self.plugins.worklet.class_reference_replacements.get(raw) != source) return false;
    const previous = self.plugins.worklet.class_reference_origins.get(@backingInt(source)) orelse return false;
    const current = self.plugins.worklet.class_reference_origins.get(raw) orelse return false;
    const own = self.static_class_reference_origins.get(raw) orelse return false;
    if (current.factory != previous.factory or current.symbol == previous.symbol or own.source != source or
        own.source_symbol_id != @backingInt(previous.symbol) or own.reference.symbol_id != current.symbol or
        own.reference.scope_id != current.scope or !std.meta.eql(own.reference.flags, current.flags) or
        self.exact_output_ref_scope_ids.get(raw) != @backingInt(current.scope) or
        self.exact_output_ref_symbol_ids.get(raw) != @backingInt(current.symbol)) return false;
    return @import("static_class_capture.zig").validOwnReferenceOrigin(self, replacement);
}
