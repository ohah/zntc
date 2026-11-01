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
    var captured = factory;
    captured.source_birth = captureClass(self, factory.source_class, factory.source_scope, factory.source_self);
    captured.target_birth = captureClass(self, factory.target_class, factory.target_scope, factory.target_self);
    captured.creator_epoch = self.semantic_editor.?.scope_history.epoch();
    const creators = &self.semantic_editor.?.scope_history.worklet_class_creators;
    captured.creator_index = @intCast(creators.items.len);
    try creators.append(self.allocator, .{
        .source = captured.source_birth.?,
        .target = captured.target_birth.?,
        .factory = captured.function,
        .factory_binding = captured.binding,
        .factory_symbol = captured.symbol,
        .factory_scope = captured.scope,
        .wrapper_scope = captured.parent,
        .epoch = captured.creator_epoch,
    });
    try self.plugins.worklet.class_factories.append(self.allocator, captured);
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
    const factory_owners = try self.allocator.alloc(ast.NodeIndex, self.plugins.worklet.class_factories.items.len);
    defer self.allocator.free(factory_owners);
    @memset(factory_owners, .none);
    for (self.plugins.worklet.class_factories.items, 0..) |factory, factory_index| {
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
            factory_owners[factory_index] = @fromBackingInt(@as(u32, @intCast(raw)));
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
    var next_publications: std.AutoHashMapUnmanaged(u32, state.WorkletClassPublication) = .empty;
    errdefer next_publications.deinit(self.allocator);
    for (updated) |reference| {
        const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        if (node.isNone()) continue;
        const birth = self.plugins.worklet.class_reference_origins.get(@backingInt(node)) orelse continue;
        if (birth.symbol != reference.symbol_id or birth.scope != reference.scope_id or !std.meta.eql(birth.flags, reference.flags))
            return error.InvalidWorkletCloneOrigin;
        const slot = try next_publications.getOrPut(self.allocator, @backingInt(node));
        if (slot.found_existing) return error.InvalidWorkletCloneOrigin;
        slot.value_ptr.* = .{ .ast_owner = self.ast, .factory = birth.factory, .owner = factory_owners[birth.factory], .flags = birth.flags, .value = .{ .symbol_id = birth.symbol, .scope = birth.scope, .stmt = reference.stmt_idx, .scope_stmt = reference.scope_stmt_idx } };
    }
    for (updated, indices.items) |reference, index| {
        editor.references.items[index].stmt_idx = reference.stmt_idx;
        editor.references.items[index].scope_stmt_idx = reference.scope_stmt_idx;
    }
    self.plugins.worklet.class_publications.deinit(self.allocator);
    self.plugins.worklet.class_publications = next_publications;
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

/// Class declarations inside a known factory are local storage, not captures.
/// Classify each exact read before the legacy name-keyed closure tables can
/// conflate it with a same-spelled external class. Other worklets retain their
/// existing closure analysis.
pub fn ownsClosureClassReference(self: anytype, function: ast.NodeIndex, node: ast.NodeIndex) bool {
    if (!self.semantic_edit_enabled or function.isNone() or node.isNone()) return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    const raw = @backingInt(node);
    const origin = self.plugins.worklet.class_reference_origins.get(raw) orelse return false;
    if (origin.factory >= self.plugins.worklet.class_factories.items.len or !origin.flags.read or origin.flags.declare or
        raw >= editor.symbol_ids.items.len or editor.symbol_ids.items[raw] != @backingInt(origin.symbol) or
        @backingInt(origin.symbol) >= editor.symbols.items.len) return false;
    const factory = self.plugins.worklet.class_factories.items[origin.factory];
    if (factory.ast_owner != self.ast or self.current_scope != factory.scope or self.outputOwnedScope(function) != factory.scope or
        factory.scope.isNone() or factory.scope.toIndex() >= editor.scopes.items.len) return false;
    const owner = self.ast.getNode(function);
    if (owner.tag != .function_declaration and owner.tag != .function_expression) return false;
    const binding = self.ast.readExtraNode(owner.data.extra, ast.FunctionExtra.name);
    if (binding != factory.binding or @backingInt(binding) >= editor.symbol_ids.items.len or
        editor.symbol_ids.items[@backingInt(binding)] != @backingInt(factory.symbol)) return false;
    const storage = editor.symbols.items[@backingInt(origin.symbol)];
    if (storage.kind != .class_decl or !ownedScopeReachesFactory(self, storage.scope_id, factory.scope) or
        !ownedScopeReachesFactory(self, origin.scope, factory.scope)) return false;
    var reads: usize = 0;
    var declaration = false;
    for (editor.references.items) |row| {
        if (row.node_index == node) {
            if (row.symbol_id != origin.symbol or row.scope_id != origin.scope or !std.meta.eql(row.flags, origin.flags)) return false;
            reads += 1;
        }
        if (!row.flags.declare or row.symbol_id != origin.symbol or row.scope_id != storage.scope_id or row.declaration_node_index.isNone()) continue;
        const anchor = @backingInt(row.declaration_node_index);
        const birth = self.plugins.worklet.class_reference_origins.get(anchor) orelse continue;
        if (birth.factory == origin.factory and birth.symbol == origin.symbol and birth.scope == storage.scope_id and
            std.meta.eql(birth.flags, row.flags) and anchor < editor.symbol_ids.items.len and editor.symbol_ids.items[anchor] == @backingInt(origin.symbol))
            declaration = true;
    }
    if (reads != 1) return false;
    if (declaration) return true;
    // Immutable class-self declarations may be anchorless. Their exact class
    // creator map and live owner are the declaration evidence instead.
    if (editor.scopes.items[storage.scope_id.toIndex()].kind != .class_body) return false;
    var selves = self.class_self_symbol_map.iterator();
    while (selves.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(origin.symbol)) continue;
        const class: ast.NodeIndex = @fromBackingInt(entry.key_ptr.*);
        if (self.outputOwnedScope(class) != storage.scope_id) continue;
        const tag = self.ast.getNode(class).tag;
        if (tag == .class_declaration or tag == .class_expression) return true;
    }
    return false;
}

fn ownedScopeReachesFactory(self: anytype, start: @import("../semantic/scope.zig").ScopeId, factory: @import("../semantic/scope.zig").ScopeId) bool {
    const editor = &self.semantic_editor.?;
    var scope = start;
    var hops: usize = 0;
    while (scope != factory) : (hops += 1) {
        if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len or hops >= editor.scopes.items.len) return false;
        var owned = false;
        var owners = self.scope_owner_origins.iterator();
        while (owners.next()) |entry| {
            if (self.outputOwnedScope(@fromBackingInt(entry.key_ptr.*)) == scope) {
                owned = true;
                break;
            }
        }
        if (!owned and !isFunctionNameEnvironment(self, scope)) return false;
        scope = editor.scopes.items[scope.toIndex()].parent;
    }
    return true;
}

// A named function expression has a lexical name environment without an AST
// scope owner. Admit only its exact binding and actual function/formal chain.
fn isFunctionNameEnvironment(self: anytype, scope: @import("../semantic/scope.zig").ScopeId) bool {
    const editor = &self.semantic_editor.?;
    if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[scope.toIndex()].kind != .block) return false;
    var matches: usize = 0;
    var owners = self.scope_owner_origins.iterator();
    while (owners.next()) |entry| {
        const function: ast.NodeIndex = @fromBackingInt(entry.key_ptr.*);
        const node = self.ast.getNode(function);
        if (node.tag != .function_expression) continue;
        const body_scope = self.outputOwnedScope(function) orelse continue;
        if (body_scope.isNone() or body_scope.toIndex() >= editor.scopes.items.len) continue;
        const name = self.ast.readExtraNode(node.data.extra, ast.FunctionExtra.name);
        if (name.isNone() or @backingInt(name) >= editor.symbol_ids.items.len) continue;
        const sid = editor.symbol_ids.items[@backingInt(name)] orelse continue;
        if (sid >= editor.symbols.items.len) continue;
        const name_symbol = editor.symbols.items[sid];
        if (name_symbol.kind != .function_decl or name_symbol.scope_id != scope) continue;
        var inner = body_scope;
        const params = self.ast.readExtraNode(node.data.extra, ast.FunctionExtra.params);
        if (!params.isNone()) if (self.outputOwnedScope(params)) |parameter_scope| {
            if (parameter_scope.isNone() or parameter_scope.toIndex() >= editor.scopes.items.len or
                editor.scopes.items[body_scope.toIndex()].parent != parameter_scope) continue;
            inner = parameter_scope;
        };
        if (editor.scopes.items[inner.toIndex()].parent != scope) continue;
        matches += 1;
    }
    return matches == 1;
}

/// The generated factory declaration is consumed by the ordinary function
/// visitor. Publish its existing owner on the fresh result before plugin
/// dispatch needs that actual function identity; unrelated functions do not
/// enter this handoff.
pub fn transferFactoryFunctionOwner(self: anytype, source: ast.NodeIndex, result: ast.NodeIndex) !void {
    if (!self.semantic_edit_enabled) return;
    for (self.plugins.worklet.class_factories.items) |factory| {
        if (factory.function != source) continue;
        const editor = &self.semantic_editor.?;
        if (factory.ast_owner != self.ast or self.outputOwnedScope(source) != factory.scope or
            self.current_scope != factory.scope or self.ast.getNode(source).tag != .function_declaration or
            self.ast.getNode(result).tag != .function_declaration or
            self.ast.readExtraNode(self.ast.getNode(source).data.extra, ast.FunctionExtra.name) != factory.binding or
            self.ast.readExtraNode(self.ast.getNode(result).data.extra, ast.FunctionExtra.name) != factory.binding or
            editor.symbol_ids.items[@backingInt(factory.binding)] != @backingInt(factory.symbol))
            @panic("worklet factory result lost its exact source function owner");
        const source_params = self.ast.readExtraNode(self.ast.getNode(source).data.extra, ast.FunctionExtra.params);
        const output_params = self.ast.readExtraNode(self.ast.getNode(result).data.extra, ast.FunctionExtra.params);
        const carrier = self.outputOwnedScope(source_params);
        if (self.ast.getNode(source_params).tag != .formal_parameters or self.ast.getNode(output_params).tag != .formal_parameters or
            self.ast.getNode(source_params).data.list.len != 0 or self.ast.getNode(output_params).data.list.len != 0 or
            carrier != self.outputOwnedScope(output_params) or (carrier != null and carrier.? != factory.scope))
            @panic("worklet factory result changed its known empty formal carrier");
        try self.remapCopiedScopeOwner(source, result);
        return;
    }
}

pub const ReferenceScopeMove = struct {
    ast_owner: *const ast.Ast,
    node: ast.NodeIndex,
    before: symbol.Reference,
    birth: state.WorkletClassReferenceOrigin,
    storage_scope: @import("../semantic/scope.zig").ScopeId,
    target: @import("../semantic/scope.zig").ScopeId,
    planned: bool,
};

/// Called only by an existing exact initializer-fragment mover, before it
/// changes the row. A missing worklet participant leaves the old path alone.
pub fn prepareReferenceScopeMove(self: anytype, node: ast.NodeIndex, before: symbol.Reference, target: @import("../semantic/scope.zig").ScopeId) !?ReferenceScopeMove {
    const raw = @backingInt(node);
    const birth = self.plugins.worklet.class_reference_origins.get(raw) orelse return null;
    const editor = &self.semantic_editor.?;
    if (birth.factory >= self.plugins.worklet.class_factories.items.len or before.flags.declare or before.node_index != node or
        before.symbol_id != birth.symbol or before.scope_id != birth.scope or !std.meta.eql(before.flags, birth.flags) or
        raw >= editor.symbol_ids.items.len or editor.symbol_ids.items[raw] != @backingInt(birth.symbol) or
        @backingInt(birth.symbol) >= editor.symbols.items.len) return error.InvalidWorkletCloneOrigin;
    const factory = self.plugins.worklet.class_factories.items[birth.factory];
    if (factory.ast_owner != self.ast) return error.InvalidWorkletFactoryOwner;
    var scope = target;
    var hops: usize = 0;
    while (scope != factory.scope) : (hops += 1) {
        if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len or hops >= editor.scopes.items.len)
            return error.InvalidWorkletCloneOrigin;
        scope = editor.scopes.items[scope.toIndex()].parent;
    }
    const planned_symbol = self.exact_output_ref_symbol_ids.get(raw);
    const planned_scope = self.exact_output_ref_scope_ids.get(raw);
    if ((planned_symbol == null) != (planned_scope == null) or
        (planned_symbol != null and (planned_symbol.? != @backingInt(birth.symbol) or planned_scope.? != @backingInt(birth.scope))))
        return error.InvalidWorkletCloneOrigin;
    return .{ .ast_owner = self.ast, .node = node, .before = before, .birth = birth, .storage_scope = editor.symbols.items[@backingInt(birth.symbol)].scope_id, .target = target, .planned = planned_symbol != null };
}

/// The selected mover has now changed this exact existing row. Only its use
/// Scope and an already-existing exact plan may follow that known handoff.
pub fn completeReferenceScopeMove(self: anytype, move: ReferenceScopeMove) !void {
    if (move.ast_owner != self.ast) return error.InvalidWorkletCloneOrigin;
    const editor = &self.semantic_editor.?;
    const raw = @backingInt(move.node);
    const origin = self.plugins.worklet.class_reference_origins.getPtr(raw) orelse return error.MissingWorkletCloneOrigin;
    if (!std.meta.eql(origin.*, move.birth) or move.before.node_index != move.node or
        editor.symbols.items[@backingInt(move.birth.symbol)].scope_id != move.storage_scope) return error.InvalidWorkletCloneOrigin;
    const row = (try editor.referenceForNode(move.node)) orelse return error.InvalidWorkletCloneOrigin;
    if (row.symbol_id != move.before.symbol_id or row.scope_id != move.target or !std.meta.eql(row.flags, move.before.flags))
        return error.InvalidWorkletCloneOrigin;
    if (move.planned) {
        const planned = self.exact_output_ref_scope_ids.getPtr(raw) orelse return error.InvalidWorkletCloneOrigin;
        if (self.exact_output_ref_symbol_ids.get(raw) != @backingInt(move.birth.symbol) or
            (planned.* != @backingInt(move.before.scope_id) and planned.* != @backingInt(move.target))) return error.InvalidWorkletCloneOrigin;
        planned.* = @backingInt(move.target);
    } else if (self.exact_output_ref_symbol_ids.contains(raw) or self.exact_output_ref_scope_ids.contains(raw)) return error.InvalidWorkletCloneOrigin;
    origin.scope = move.target;
}

/// A key is being assembled outside this exact reconstructed class body.
/// The actual key producer supplies its output scope; no other class enters
/// this worklet-only source-fragment handoff.
pub fn moveHoistedKeyReferences(self: anytype, source_class: ast.NodeIndex, fragment: ast.NodeIndex, target: @import("../semantic/scope.zig").ScopeId) !void {
    if (!self.semantic_edit_enabled or source_class.isNone()) return;
    for (self.plugins.worklet.class_factories.items) |factory| {
        if (factory.target_class != source_class) continue;
        if (factory.ast_owner != self.ast or self.outputOwnedScope(source_class) != factory.target_scope or
            self.class_self_symbol_map.get(@backingInt(source_class)) != @backingInt(factory.target_self))
            @panic("hoisted worklet key lost its exact class creator");
        try @import("class_strict_context.zig").moveSourceReferences(self, fragment, factory.target_scope, factory.target_scope, target);
        return;
    }
}

/// Fully lowered native formals now bind in the actual function body, rather
/// than the removed non-simple parameter environment. Retained non-simple
/// carriers never call this entry. Only exact cloned parameter declarations
/// participate; ordinary/source-only functions keep their existing path.
pub fn handoffSimpleParameterDeclarations(self: anytype, function: ast.NodeIndex, old_params: ast.NodeIndex, new_params: ast.NodeIndex, body_scope: @import("../semantic/scope.zig").ScopeId) !void {
    if (!self.semantic_edit_enabled or self.plugins.worklet.class_reference_origins.count() == 0) return;
    const editor = &self.semantic_editor.?;
    const list = self.ast.getNode(new_params).data.list;
    for (0..list.len) |offset| {
        const parameter = self.ast.readExtraNode(list.start, @intCast(offset));
        const binding = @import("native_constructor_timing.zig").simpleFormalBinding(self, parameter) orelse continue;
        const raw = @backingInt(binding);
        const birth = self.plugins.worklet.class_reference_origins.get(raw) orelse continue;
        if (!birth.flags.declare) continue;
        if (body_scope.isNone() or body_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[body_scope.toIndex()].kind != .function or
            self.current_scope != body_scope or self.outputOwnedScope(function) != body_scope or
            self.ast.readExtraNode(self.ast.getNode(function).data.extra, ast.FunctionExtra.params) != new_params) return error.InvalidWorkletCloneOrigin;
        if (birth.scope == body_scope) continue;
        const source_scope = self.outputOwnedScope(old_params) orelse return error.InvalidWorkletCloneOrigin;
        if (birth.factory >= self.plugins.worklet.class_factories.items.len or source_scope != birth.scope or body_scope.isNone() or
            body_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[body_scope.toIndex()].parent != source_scope or
            self.outputOwnedScope(function) != body_scope or self.ast.readExtraNode(self.ast.getNode(function).data.extra, ast.FunctionExtra.params) != new_params or
            self.outputOwnedScope(new_params) != null or raw >= editor.symbol_ids.items.len or editor.symbol_ids.items[raw] != @backingInt(birth.symbol) or
            @backingInt(birth.symbol) >= editor.symbols.items.len) return error.InvalidWorkletCloneOrigin;
        const factory = self.plugins.worklet.class_factories.items[birth.factory];
        if (factory.ast_owner != self.ast) return error.InvalidWorkletFactoryOwner;
        const storage = editor.symbols.items[@backingInt(birth.symbol)];
        if (storage.kind != .parameter or storage.scope_id != source_scope) return error.InvalidWorkletCloneOrigin;
        var declarations: usize = 0;
        for (editor.references.items) |row| {
            if (row.symbol_id != birth.symbol or !row.flags.declare) continue;
            if (row.declaration_node_index != binding or row.scope_id != source_scope or !std.meta.eql(row.flags, birth.flags))
                return error.InvalidWorkletCloneOrigin;
            declarations += 1;
        }
        if (declarations != 1) return error.InvalidWorkletCloneOrigin;
        // Relocate the same selected binding. The editor preserves its flags,
        // anchors and original source scope, and rejects a conflicting cell.
        try editor.moveSymbolToScope(birth.symbol, body_scope);
        self.plugins.worklet.class_reference_origins.getPtr(raw).?.scope = body_scope;
    }
}

pub const ClassSelfStorageMove = struct {
    ast_owner: *ast.Ast,
    factory: usize,
    source_class: ast.NodeIndex,
    binding: ast.NodeIndex,
    symbol_id: symbol.SymbolId,
    before: @import("../semantic/scope.zig").ScopeId,
    target: @import("../semantic/scope.zig").ScopeId,
    origins: []const Origin,
    const Origin = struct { node: u32, birth: state.WorkletClassReferenceOrigin };
};

/// The class lowerer has selected this exact cloned class-self storage, before
/// moving the symbol. Uses keep their own scopes; only declaration carriers
/// follow the same selected binding's storage transition.
pub fn prepareClassSelfStorageMove(self: anytype, class: ast.NodeIndex, binding: ast.NodeIndex, id: symbol.SymbolId, target: @import("../semantic/scope.zig").ScopeId) !?ClassSelfStorageMove {
    if (!self.semantic_edit_enabled) return null;
    const editor = &self.semantic_editor.?;
    for (self.plugins.worklet.class_factories.items, 0..) |factory, index| {
        if (factory.target_class != class) continue;
        if (@backingInt(id) >= editor.symbols.items.len or factory.target_scope.isNone() or factory.target_scope.toIndex() >= editor.scopes.items.len) return error.InvalidWorkletCloneOrigin;
        const old = editor.symbols.items[@backingInt(id)].scope_id;
        if (factory.ast_owner != self.ast or factory.target_self != id or self.class_self_symbol_map.get(@backingInt(class)) != @backingInt(id) or
            self.outputOwnedScope(class) != factory.target_scope or target.isNone() or target.toIndex() >= editor.scopes.items.len or
            editor.scopes.items[target.toIndex()].kind != .function or editor.scopes.items[factory.target_scope.toIndex()].parent != target or
            editor.scopes.items[target.toIndex()].parent != factory.scope or self.ast.getNode(binding).tag != .binding_identifier)
            return error.InvalidWorkletCloneOrigin;
        var origins: std.ArrayList(ClassSelfStorageMove.Origin) = .empty;
        errdefer origins.deinit(self.allocator);
        var entries = self.plugins.worklet.class_reference_origins.iterator();
        while (entries.next()) |entry| {
            const birth = entry.value_ptr.*;
            if (birth.factory != index or birth.symbol != id or !birth.flags.declare) continue;
            if (birth.scope != old or entry.key_ptr.* != @backingInt(binding) or
                entry.key_ptr.* >= editor.symbol_ids.items.len or editor.symbol_ids.items[entry.key_ptr.*] != @backingInt(id)) return error.InvalidWorkletCloneOrigin;
            var count: usize = 0;
            for (editor.references.items) |row| {
                if (@backingInt(row.declaration_node_index) != entry.key_ptr.* or !row.flags.declare) continue;
                if (row.symbol_id != id or row.scope_id != old or !std.meta.eql(row.flags, birth.flags)) return error.InvalidWorkletCloneOrigin;
                count += 1;
            }
            if (count != 1) return error.InvalidWorkletCloneOrigin;
            try origins.append(self.allocator, .{ .node = entry.key_ptr.*, .birth = birth });
        }
        if (origins.items.len == 0) return error.InvalidWorkletCloneOrigin;
        return .{ .ast_owner = self.ast, .factory = index, .source_class = class, .binding = binding, .symbol_id = id, .before = old, .target = target, .origins = try origins.toOwnedSlice(self.allocator) };
    }
    return null;
}

pub fn completeClassSelfStorageMove(self: anytype, move: ClassSelfStorageMove) !void {
    const editor = &self.semantic_editor.?;
    if (move.ast_owner != self.ast or move.factory >= self.plugins.worklet.class_factories.items.len or
        self.plugins.worklet.class_factories.items[move.factory].target_class != move.source_class or
        self.plugins.worklet.class_factories.items[move.factory].target_self != move.symbol_id or
        self.getSymbolIdAt(move.binding) != @as(?u32, @backingInt(move.symbol_id)) or
        editor.symbols.items[@backingInt(move.symbol_id)].scope_id != move.target) return error.InvalidWorkletCloneOrigin;
    if (move.origins.len != 1) return error.InvalidWorkletCloneOrigin;
    const original = move.origins[0];
    const current = self.plugins.worklet.class_reference_origins.get(original.node) orelse return error.MissingWorkletCloneOrigin;
    if (!std.meta.eql(current, original.birth) or current.scope != move.before) return error.InvalidWorkletCloneOrigin;
    var count: usize = 0;
    for (editor.references.items) |row| {
        if (!row.flags.declare or row.symbol_id != move.symbol_id) continue;
        if (row.declaration_node_index != move.binding or row.scope_id != move.target or !std.meta.eql(row.flags, original.birth.flags)) return error.InvalidWorkletCloneOrigin;
        count += 1;
    }
    if (count != 1) return error.InvalidWorkletCloneOrigin;
    if (@backingInt(move.binding) != original.node) return error.InvalidWorkletCloneOrigin;
    self.plugins.worklet.class_reference_origins.getPtr(original.node).?.scope = move.target;
}

/// A consumer may preserve only an actual published tuple. Missing worklet
/// publication is an error, never a general waiver for an existing row.
pub fn publication(self: anytype, raw: u32) @import("../semantic/editor.zig").Error!?@import("transformer.zig").StatementPublication {
    const birth = self.plugins.worklet.class_reference_origins.get(raw) orelse {
        if (self.plugins.worklet.class_publications.contains(raw)) return error.InvalidNode;
        return null;
    };
    const known = self.plugins.worklet.class_publications.get(raw) orelse return error.InvalidNode;
    const editor = &self.semantic_editor.?;
    if (known.ast_owner != self.ast or known.factory != birth.factory or birth.factory >= self.plugins.worklet.class_factories.items.len)
        return error.InvalidNode;
    const factory = self.plugins.worklet.class_factories.items[birth.factory];
    if (factory.ast_owner != self.ast or @backingInt(known.owner) >= self.ast.nodes.items.len or factory.scope.isNone() or
        factory.scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[factory.scope.toIndex()].kind != .function or
        editor.scopes.items[factory.scope.toIndex()].parent != factory.parent or self.outputOwnedScope(known.owner) != factory.scope)
        return error.InvalidNode;
    const owner = self.ast.getNode(known.owner);
    if ((owner.tag != .function_declaration and owner.tag != .function_expression) or
        self.ast.readExtraNode(owner.data.extra, ast.FunctionExtra.name) != factory.binding or
        self.getSymbolIdAt(factory.binding) != @as(?u32, @backingInt(factory.symbol))) return error.InvalidNode;
    if (known.value.symbol_id != birth.symbol or self.getSymbolIdAt(@fromBackingInt(raw)) != @as(?u32, @backingInt(birth.symbol))) return error.InvalidSymbol;
    if (known.value.scope != birth.scope) return error.InvalidScope;
    if (!std.meta.eql(known.flags, birth.flags)) return error.InvalidNode;
    var rows: usize = 0;
    for (editor.references.items) |row| {
        const anchor = if (row.flags.declare) row.declaration_node_index else row.node_index;
        if (anchor != @as(ast.NodeIndex, @fromBackingInt(raw))) continue;
        if (row.symbol_id != known.value.symbol_id) return error.InvalidSymbol;
        if (row.scope_id != known.value.scope) return error.InvalidScope;
        if (!std.meta.eql(row.flags, known.flags) or row.stmt_idx != known.value.stmt or row.scope_stmt_idx != known.value.scope_stmt) return error.InvalidNode;
        rows += 1;
    }
    if (rows != 1) return error.ReferenceNotFound;
    return known.value;
}

pub fn agreePublication(self: anytype, raw: u32, other: ?@import("transformer.zig").StatementPublication, flags: symbol.ReferenceFlags) @import("../semantic/editor.zig").Error!?@import("transformer.zig").StatementPublication {
    const worklet = try publication(self, raw);
    if (worklet != null and !std.meta.eql(self.plugins.worklet.class_publications.get(raw).?.flags, flags)) return error.InvalidNode;
    if (other != null and worklet != null) {
        if (other.?.symbol_id != worklet.?.symbol_id) return error.InvalidSymbol;
        if (other.?.scope != worklet.?.scope) return error.InvalidScope;
        if (other.?.stmt != worklet.?.stmt or other.?.scope_stmt != worklet.?.scope_stmt) return error.InvalidNode;
    }
    return other orelse worklet;
}

fn captureClass(self: anytype, node: ast.NodeIndex, scope: @import("../semantic/scope.zig").ScopeId, id: symbol.SymbolId) @import("../semantic/lowered_worklet_class.zig").Class {
    const value = self.ast.getNode(node);
    return .{ .node = node, .name = self.ast.readExtraNode(value.data.extra, ast.ClassExtra.name), .body = self.ast.readExtraNode(value.data.extra, ast.ClassExtra.body), .scope = scope, .self = id };
}

fn captureFunction(self: anytype, node: ast.NodeIndex, scope: @import("../semantic/scope.zig").ScopeId, parent: @import("../semantic/scope.zig").ScopeId, declaration: ast.NodeIndex, id: symbol.SymbolId) @import("../semantic/lowered_worklet_class.zig").Function {
    const value = self.ast.getNode(node);
    return .{ .node = node, .name = self.ast.readExtraNode(value.data.extra, ast.FunctionExtra.name), .params = self.ast.readExtraNode(value.data.extra, ast.FunctionExtra.params), .body = self.ast.readExtraNode(value.data.extra, ast.FunctionExtra.body), .scope = scope, .parent = parent, .declaration = declaration, .symbol = id };
}

/// Publish this logical class environment only from the actual class clone
/// creator and the lowerer which has just completed its emitted functions.
/// Its original ScopeKind and SymbolId origins remain unchanged.
pub fn recordLoweredClass(self: anytype, class: ast.NodeIndex, constructor: ast.NodeIndex, iife: ast.NodeIndex, iife_scope: @import("../semantic/scope.zig").ScopeId) !void {
    if (!self.semantic_edit_enabled) return;
    for (self.plugins.worklet.class_factories.items) |factory| {
        if (factory.target_class != class) continue;
        const editor = &self.semantic_editor.?;
        if (factory.ast_owner != self.ast or self.outputOwnedScope(class) != factory.target_scope or
            self.class_self_symbol_map.get(@backingInt(class)) != @as(?u32, @backingInt(factory.target_self)) or
            iife_scope.isNone() or self.outputOwnedScope(iife) != iife_scope or
            editor.scopes.items[iife_scope.toIndex()].parent != factory.scope or
            editor.scopes.items[factory.target_scope.toIndex()].parent != iife_scope)
            @panic("lowered worklet class lost its actual creator/output frame");
        const ctor_scope = self.outputOwnedScope(constructor) orelse @panic("lowered worklet class has no actual constructor frame");
        const name = self.ast.readExtraNode(self.ast.getNode(constructor).data.extra, ast.FunctionExtra.name);
        if (name.isNone() or editor.symbol_ids.items[@backingInt(name)] != @as(?u32, @backingInt(factory.target_self)))
            @panic("lowered worklet constructor lost its exact class-self binding");
        for (editor.scope_history.lowered_worklet_classes.items) |previous| {
            if (previous.target.scope == factory.target_scope) @panic("worklet class environment published twice");
        }
        try editor.scope_history.lowered_worklet_classes.append(self.allocator, .{
            .creator_index = factory.creator_index orelse @panic("lowered class has no actual creator receipt"),
            .source = factory.source_birth orelse @panic("worklet class has no source birth"),
            .target = factory.target_birth orelse @panic("worklet class has no target birth"),
            .factory = captureFunction(self, factory.function, factory.scope, factory.parent, factory.binding, factory.symbol),
            .wrapper_scope = factory.parent,
            .constructor = captureFunction(self, constructor, ctor_scope, self.outputScopeParent(ctor_scope), name, factory.target_self),
            .iife = captureFunction(self, iife, iife_scope, factory.scope, .none, .none),
            .creator_epoch = factory.creator_epoch,
            .lowered_epoch = editor.scope_history.epoch(),
        });
        return;
    }
}
