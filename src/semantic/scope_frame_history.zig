//! Ordered, source-owned lexical frame edits. Symbol counts are not replayed:
//! declaration/count consistency remains the independent exact graph audit.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scope = @import("scope.zig").Scope;
const ScopeId = @import("scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;
pub const Error = std.mem.Allocator.Error || error{ InvalidScope, InvalidNode, InvalidHistory };

/// Meaningful node payload only, never untagged-union padding.
pub const Owner = struct {
    node: NodeIndex,
    tag: ast_mod.Node.Tag,
    span: @import("../lexer/token.zig").Span,
    words: [3]u32 = @splat(0),

    pub fn capture(tree: *const ast_mod.Ast, node: NodeIndex) Error!?Owner {
        if (node.isNone()) return null;
        if (@backingInt(node) >= tree.nodes.items.len) return error.InvalidNode;
        const n = tree.getNode(node);
        var result: Owner = .{ .node = node, .tag = n.tag, .span = n.span };
        switch (ast_mod.Node.Tag.dataKind(n.tag)) {
            .extra => result.words[0] = n.data.extra,
            .list => result.words = .{ n.data.list.start, n.data.list.len, 0 },
            .binary => result.words = .{ @backingInt(n.data.binary.left), @backingInt(n.data.binary.right), n.data.binary.flags },
            .ternary => result.words = .{ @backingInt(n.data.ternary.a), @backingInt(n.data.ternary.b), @backingInt(n.data.ternary.c) },
            .unary => result.words = .{ @backingInt(n.data.unary.operand), n.data.unary.flags, 0 },
            .leaf => switch (n.tag) {
                .empty_statement => {},
                .binding_identifier, .identifier_reference, .assignment_target_identifier, .jsx_identifier => result.words = .{ n.data.string_ref.start, n.data.string_ref.end, 0 },
                else => return error.InvalidNode,
            },
        }
        return result;
    }
};
/// Child carriers captured from the initial graph or the actual publication
/// of a generated owner. Owner.words and event replay keep their header contract.
pub const SourceEdges = struct {
    parameters: NodeIndex = .none,
    body: NodeIndex = .none,
    heritage: NodeIndex = .none,
};
pub const OwnerBinding = struct { scope: ScopeId, owner: Owner, edges: SourceEdges = .{} };

/// A direct static field's original evaluation subtree. These carriers are
/// captured from the actual initial class body, never from a lowered factory.
pub const InitializerSource = struct {
    scope: ScopeId,
    class_owner: Owner,
    field: Owner,
    initializer: Owner,
    leaf: Owner,
};

/// Ordinary reads in the actual initial awaited computed-key subtree.
/// No global spelling or later state-machine expression grants this authority.
pub const ComputedAwaitSource = struct {
    scope: ScopeId,
    class_owner: Owner,
    declaration: Owner,
    key: Owner,
    await_node: Owner,
    leaf: Owner,
};

/// Actual initial class computed-key reads; captured before any key hoist.
pub const ClassKeySource = struct {
    scope: ScopeId,
    class_owner: Owner,
    body: Owner,
    member: Owner,
    member_slot: u32,
    key: Owner,
    leaf: Owner,
};

fn captureClassKeySources(a: std.mem.Allocator, tree: *const ast_mod.Ast, binding: OwnerBinding, out: *std.ArrayList(ClassKeySource)) Error!void {
    if (binding.owner.tag != .class_declaration and binding.owner.tag != .class_expression) return;
    const body_index = binding.edges.body;
    if (body_index.isNone() or @backingInt(body_index) >= tree.nodes.items.len) return error.InvalidNode;
    const body = tree.getNode(body_index);
    if (body.tag != .class_body or body.data.list.start > tree.extra_data.items.len or body.data.list.len > tree.extra_data.items.len - body.data.list.start) return error.InvalidNode;
    for (tree.extra_data.items[body.data.list.start..][0..body.data.list.len], 0..) |raw, offset| {
        if (raw >= tree.nodes.items.len) return error.InvalidNode;
        const member = tree.nodes.items[raw];
        if (member.tag != .method_definition and member.tag != .property_definition and member.tag != .accessor_property) continue;
        if (!tree.hasExtra(member.data.extra, 0)) return error.InvalidNode;
        const key_index = tree.readExtraNode(member.data.extra, 0);
        if (key_index.isNone() or @backingInt(key_index) >= tree.nodes.items.len) continue;
        const key = tree.getNode(key_index);
        if (key.tag != .computed_property_key) continue;
        const references = try @import("reference_walk.zig").collectIdentifierReferences(a, tree, key.data.unary.operand);
        defer a.free(references);
        for (references) |leaf| {
            if (tree.getNode(leaf).tag != .identifier_reference) continue;
            try out.append(a, .{ .scope = binding.scope, .class_owner = binding.owner, .body = (try Owner.capture(tree, body_index)).?, .member = (try Owner.capture(tree, @fromBackingInt(raw))).?, .member_slot = @intCast(body.data.list.start + offset), .key = (try Owner.capture(tree, key_index)).?, .leaf = (try Owner.capture(tree, leaf)).? });
        }
    }
}

fn captureComputedAwaitSources(a: std.mem.Allocator, tree: *const ast_mod.Ast, binding: OwnerBinding, out: *std.ArrayList(ComputedAwaitSource)) Error!void {
    if (binding.owner.tag != .class_declaration and binding.owner.tag != .class_expression) return;
    if (binding.edges.body.isNone() or @backingInt(binding.edges.body) >= tree.nodes.items.len) return error.InvalidNode;
    const body = tree.getNode(binding.edges.body);
    if (body.tag != .class_body or body.data.list.start > tree.extra_data.items.len or body.data.list.len > tree.extra_data.items.len - body.data.list.start) return error.InvalidNode;
    for (tree.extra_data.items[body.data.list.start..][0..body.data.list.len]) |raw| {
        if (raw >= tree.nodes.items.len) return error.InvalidNode;
        const declaration = tree.nodes.items[raw];
        switch (declaration.tag) {
            .method_definition, .property_definition, .accessor_property => {},
            else => continue,
        }
        if (!tree.hasExtra(declaration.data.extra, 0)) return error.InvalidNode;
        const key_index = tree.readExtraNode(declaration.data.extra, 0);
        if (key_index.isNone() or @backingInt(key_index) >= tree.nodes.items.len) continue;
        const key = tree.getNode(key_index);
        if (key.tag != .computed_property_key) continue;
        const await_index = key.data.unary.operand;
        if (await_index.isNone() or @backingInt(await_index) >= tree.nodes.items.len) continue;
        const await_node = tree.getNode(await_index);
        if (await_node.tag != .await_expression) continue;
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(a);
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(a);
        try stack.append(a, await_node.data.unary.operand);
        while (stack.pop()) |leaf| {
            if (leaf.isNone()) continue;
            const leaf_raw = @backingInt(leaf);
            if (leaf_raw >= tree.nodes.items.len) return error.InvalidNode;
            const seen = try visited.getOrPut(a, leaf_raw);
            if (seen.found_existing) continue;
            const value = tree.getNode(leaf);
            if (value.tag == .identifier_reference) try out.append(a, .{ .scope = binding.scope, .class_owner = binding.owner, .declaration = (try Owner.capture(tree, @fromBackingInt(raw))).?, .key = (try Owner.capture(tree, key_index)).?, .await_node = (try Owner.capture(tree, await_index)).?, .leaf = (try Owner.capture(tree, leaf)).? });
            var children = @import("../parser/ast_walk.zig").children(tree, value);
            while (children.next()) |child| try stack.append(a, child);
        }
    }
}

fn captureInitializers(a: std.mem.Allocator, tree: *const ast_mod.Ast, binding: OwnerBinding, out: *std.ArrayList(InitializerSource)) Error!void {
    if (binding.owner.tag != .class_declaration and binding.owner.tag != .class_expression) return;
    const body = binding.edges.body;
    if (body.isNone() or @backingInt(body) >= tree.nodes.items.len) return error.InvalidNode;
    const node = tree.getNode(body);
    if (node.tag != .class_body or node.data.list.start > tree.extra_data.items.len or node.data.list.len > tree.extra_data.items.len - node.data.list.start) return error.InvalidNode;
    for (tree.extra_data.items[node.data.list.start..][0..node.data.list.len]) |raw| {
        if (raw >= tree.nodes.items.len) return error.InvalidNode;
        const field = tree.nodes.items[raw];
        if (field.tag != .property_definition and field.tag != .accessor_property) continue;
        if (!tree.hasExtra(field.data.extra, ast_mod.PropertyExtra.flags)) return error.InvalidNode;
        if (tree.readExtra(field.data.extra, ast_mod.PropertyExtra.flags) & ast_mod.PropertyFlags.is_static == 0) continue;
        const init = tree.readExtraNode(field.data.extra, ast_mod.PropertyExtra.init);
        if (init.isNone()) continue;
        const owner = (try Owner.capture(tree, @fromBackingInt(raw))).?;
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(a);
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(a);
        try stack.append(a, init);
        while (stack.pop()) |leaf| {
            if (leaf.isNone()) continue;
            const leaf_raw = @backingInt(leaf);
            if (leaf_raw >= tree.nodes.items.len) return error.InvalidNode;
            const entry = try visited.getOrPut(a, leaf_raw);
            if (entry.found_existing) continue;
            const value = tree.getNode(leaf);
            if (value.tag == .identifier_reference or value.tag == .assignment_target_identifier or value.tag == .jsx_identifier)
                try out.append(a, .{ .scope = binding.scope, .class_owner = binding.owner, .field = owner, .initializer = (try Owner.capture(tree, init)).?, .leaf = (try Owner.capture(tree, leaf)).? });
            var children = @import("../parser/ast_walk.zig").children(tree, value);
            while (children.next()) |child| try stack.append(a, child);
        }
    }
}

fn captureSourceEdges(tree: *const ast_mod.Ast, owner: Owner) Error!SourceEdges {
    switch (owner.tag) {
        .function_declaration, .function_expression, .method_definition => {
            if (!tree.hasExtra(owner.words[0], ast_mod.FunctionExtra.body)) return error.InvalidNode;
            return .{ .parameters = tree.readExtraNode(owner.words[0], ast_mod.FunctionExtra.params), .body = tree.readExtraNode(owner.words[0], ast_mod.FunctionExtra.body) };
        },
        .arrow_function_expression => {
            if (!tree.hasExtra(owner.words[0], ast_mod.ArrowExtra.body)) return error.InvalidNode;
            return .{ .parameters = tree.readExtraNode(owner.words[0], ast_mod.ArrowExtra.params), .body = tree.readExtraNode(owner.words[0], ast_mod.ArrowExtra.body) };
        },
        .class_declaration, .class_expression => {
            if (!tree.hasExtra(owner.words[0], ast_mod.ClassExtra.body)) return error.InvalidNode;
            return .{ .body = tree.readExtraNode(owner.words[0], ast_mod.ClassExtra.body), .heritage = tree.readExtraNode(owner.words[0], ast_mod.ClassExtra.super) };
        },
        .static_block => return .{ .body = @fromBackingInt(owner.words[0]) },
        .for_statement => {
            if (!tree.hasExtra(owner.words[0], 3)) return error.InvalidNode;
            return .{ .body = tree.readExtraNode(owner.words[0], 3) };
        },
        .for_in_statement, .for_of_statement, .for_await_of_statement => return .{ .body = @fromBackingInt(owner.words[2]) },
        else => return .{},
    }
}
pub const Actor = struct {
    role: enum(u32) { editor, cjs_wrapper } = .editor,
    module_index: ?u32 = null,
};
pub const Event = struct {
    kind: enum(u32) { birth, frame, owner },
    scope: ScopeId,
    before: ?Scope,
    after: Scope,
    owner_before: ?Owner = null,
    owner_after: ?Owner = null,
    owner_edges: SourceEdges = .{},
    /// The actual reparent operation that caused this row change. Propagated
    /// strict/dynamic bits retain the same producer operation identity.
    trigger_scope: ScopeId = .none,
    trigger_parent: ScopeId = .none,
    parent_owner: ?Owner = null,
    actor: Actor = .{},
};
pub const History = struct {
    source_scopes: []const Scope = &.{},
    source_owners: []const OwnerBinding = &.{},
    source_initializers: []const InitializerSource = &.{},
    source_computed_awaits: []const ComputedAwaitSource = &.{},
    source_class_keys: []const ClassKeySource = &.{},
    worklet_class_creators: []const @import("lowered_worklet_class.zig").Creator = &.{},
    lowered_worklet_classes: []const @import("lowered_worklet_class.zig").Witness = &.{},
    source_dropped_statements: []const @import("source_drop_registry.zig").Statement = &.{},
    source_drop_edges: []const @import("source_drop_registry.zig").Edge = &.{},
    events: []const Event = &.{},
};

pub fn sameFrame(a: Scope, b: Scope) bool {
    return a.parent == b.parent and a.kind == b.kind and a.is_strict == b.is_strict and
        a.subtree_has_direct_eval == b.subtree_has_direct_eval and a.subtree_has_with == b.subtree_has_with;
}

/// Editor-local COW storage. finish transfers all three arrays to the graph's
/// existing arena lifetime; failed preparation can deinit this recorder.
pub const Recorder = struct {
    source_scopes: []Scope = &.{},
    source_owners: []OwnerBinding = &.{},
    source_initializers: []InitializerSource = &.{},
    source_computed_awaits: []ComputedAwaitSource = &.{},
    source_class_keys: []ClassKeySource = &.{},
    worklet_class_creators: std.ArrayList(@import("lowered_worklet_class.zig").Creator) = .empty,
    lowered_worklet_classes: std.ArrayList(@import("lowered_worklet_class.zig").Witness) = .empty,
    source_dropped_statements: std.ArrayList(@import("source_drop_registry.zig").Statement) = .empty,
    source_drop_edges: std.ArrayList(@import("source_drop_registry.zig").Edge) = .empty,
    events: std.ArrayList(Event) = .empty,
    enabled: bool = false,

    pub fn init(a: std.mem.Allocator, tree: *const ast_mod.Ast, scopes: []const Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) Error!Recorder {
        var result: Recorder = .{};
        errdefer result.deinit(a);
        result.source_scopes = try a.dupe(Scope, scopes);
        result.source_owners = try a.alloc(OwnerBinding, owners.count());
        var initializers: std.ArrayList(InitializerSource) = .empty;
        defer initializers.deinit(a);
        var computed: std.ArrayList(ComputedAwaitSource) = .empty;
        defer computed.deinit(a);
        var class_keys: std.ArrayList(ClassKeySource) = .empty;
        defer class_keys.deinit(a);
        var entries = owners.iterator();
        var i: usize = 0;
        while (entries.next()) |entry| : (i += 1) {
            if (entry.value_ptr.* >= scopes.len) return error.InvalidScope;
            const owner = (try Owner.capture(tree, @fromBackingInt(entry.key_ptr.*))) orelse return error.InvalidNode;
            result.source_owners[i] = .{ .scope = @fromBackingInt(entry.value_ptr.*), .owner = owner, .edges = try captureSourceEdges(tree, owner) };
            try captureInitializers(a, tree, result.source_owners[i], &initializers);
            try captureComputedAwaitSources(a, tree, result.source_owners[i], &computed);
            try captureClassKeySources(a, tree, result.source_owners[i], &class_keys);
        }
        result.source_initializers = try initializers.toOwnedSlice(a);
        result.source_computed_awaits = try computed.toOwnedSlice(a);
        result.source_class_keys = try class_keys.toOwnedSlice(a);
        std.mem.sortUnstable(OwnerBinding, result.source_owners, {}, struct {
            fn less(_: void, left: OwnerBinding, right: OwnerBinding) bool {
                return @backingInt(left.owner.node) < @backingInt(right.owner.node);
            }
        }.less);
        result.enabled = true;
        return result;
    }

    pub fn fromHistory(a: std.mem.Allocator, source: History) Error!Recorder {
        if (source.source_scopes.len == 0) {
            if (source.source_owners.len != 0 or source.source_initializers.len != 0 or source.source_computed_awaits.len != 0 or source.worklet_class_creators.len != 0 or source.lowered_worklet_classes.len != 0 or source.source_class_keys.len != 0 or source.source_dropped_statements.len != 0 or source.source_drop_edges.len != 0 or source.events.len != 0) return error.InvalidHistory;
            return .{};
        }
        var result: Recorder = .{};
        errdefer result.deinit(a);
        result.source_scopes = try a.dupe(Scope, source.source_scopes);
        result.source_owners = try a.dupe(OwnerBinding, source.source_owners);
        result.source_initializers = try a.dupe(InitializerSource, source.source_initializers);
        result.source_computed_awaits = try a.dupe(ComputedAwaitSource, source.source_computed_awaits);
        result.source_class_keys = try a.dupe(ClassKeySource, source.source_class_keys);
        try result.worklet_class_creators.appendSlice(a, source.worklet_class_creators);
        try result.lowered_worklet_classes.appendSlice(a, source.lowered_worklet_classes);
        try result.source_dropped_statements.appendSlice(a, source.source_dropped_statements);
        try result.source_drop_edges.appendSlice(a, source.source_drop_edges);
        try result.events.appendSlice(a, source.events);
        result.enabled = true;
        return result;
    }

    pub fn deinit(self: *Recorder, a: std.mem.Allocator) void {
        a.free(self.source_scopes);
        a.free(self.source_owners);
        a.free(self.source_initializers);
        a.free(self.source_computed_awaits);
        a.free(self.source_class_keys);
        self.worklet_class_creators.deinit(a);
        self.lowered_worklet_classes.deinit(a);
        self.source_dropped_statements.deinit(a);
        self.source_drop_edges.deinit(a);
        self.events.deinit(a);
        self.* = .{};
    }

    pub fn epoch(self: *const Recorder) u32 {
        return @intCast(self.events.items.len);
    }

    pub fn finish(self: *Recorder, a: std.mem.Allocator) Error!History {
        if (!self.enabled) return .{};
        const worklet_class_creators = try self.worklet_class_creators.toOwnedSlice(a);
        errdefer a.free(worklet_class_creators);
        const lowered_worklet_classes = try self.lowered_worklet_classes.toOwnedSlice(a);
        errdefer a.free(lowered_worklet_classes);
        const events = try self.events.toOwnedSlice(a);
        errdefer a.free(events);
        const dropped_statements = try self.source_dropped_statements.toOwnedSlice(a);
        errdefer a.free(dropped_statements);
        const drop_edges = try self.source_drop_edges.toOwnedSlice(a);
        const result: History = .{ .source_scopes = self.source_scopes, .source_owners = self.source_owners, .source_initializers = self.source_initializers, .source_computed_awaits = self.source_computed_awaits, .worklet_class_creators = worklet_class_creators, .lowered_worklet_classes = lowered_worklet_classes, .source_class_keys = self.source_class_keys, .source_dropped_statements = dropped_statements, .source_drop_edges = drop_edges, .events = events };
        self.* = .{};
        return result;
    }

    pub fn recordBirth(self: *Recorder, a: std.mem.Allocator, tree: *const ast_mod.Ast, scope: ScopeId, frame: Scope, owner: NodeIndex, actor: Actor) Error!void {
        if (!self.enabled) return;
        const header = try Owner.capture(tree, owner);
        try self.events.append(a, .{ .kind = .birth, .scope = scope, .before = null, .after = frame, .owner_after = header, .owner_edges = if (header) |h| try captureSourceEdges(tree, h) else .{}, .actor = actor });
    }

    /// Publish only the actual drop-option decision and its immutable source
    /// edge snapshots. Capacity preparation completes before either row is added.
    pub fn recordDroppedStatement(self: *Recorder, a: std.mem.Allocator, tree: *const ast_mod.Ast, source: @import("source_drop_registry.zig").Node, action: @import("source_drop_registry.zig").Action, edges: []const @import("source_drop_registry.zig").Edge, selected: NodeIndex, execution_scope: ScopeId, execution_frame: Scope, entry_epoch: u32) Error!u32 {
        const Drop = @import("source_drop_registry.zig");
        if (!self.enabled or execution_scope.isNone() or entry_epoch > self.epoch() or !source.matches(tree)) return error.InvalidHistory;
        switch (action) {
            .label => if (source.tag != .labeled_statement) return error.InvalidNode,
            .console => if (source.tag != .expression_statement or !@import("../transformer/drop_scan.zig").isConsoleCallInAst(tree, tree.getNode(source.index))) return error.InvalidNode,
            .debugger => if (source.tag != .debugger_statement) return error.InvalidNode,
        }
        const output = Drop.Node.capture(tree, selected) orelse return error.InvalidNode;
        if (source.index != selected or !std.meta.eql(source, output) or !try Drop.validatesEdges(a, tree, edges)) return error.InvalidNode;
        for (self.source_dropped_statements.items) |previous| if (previous.source.index == source.index) return error.InvalidHistory;
        if (edges.len > std.math.maxInt(u32) - self.source_drop_edges.items.len) return error.InvalidHistory;
        try self.source_dropped_statements.ensureUnusedCapacity(a, 1);
        try self.source_drop_edges.ensureUnusedCapacity(a, edges.len);
        const index: u32 = @intCast(self.source_dropped_statements.items.len);
        const start: u32 = @intCast(self.source_drop_edges.items.len);
        self.source_drop_edges.appendSliceAssumeCapacity(edges);
        self.source_dropped_statements.appendAssumeCapacity(.{
            .action = action,
            .source = source,
            .selected = output,
            .entry_epoch = entry_epoch,
            .selection_epoch = self.epoch(),
            .execution_scope = execution_scope,
            .execution_frame = execution_frame,
            .edge_start = start,
            .edge_len = @intCast(edges.len),
        });
        return index;
    }

    /// Call before publishing prepared scope rows; this cannot observe a guessed
    /// output owner. The map and both frame arrays are actual producer inputs.
    pub fn recordFrames(self: *Recorder, a: std.mem.Allocator, tree: *const ast_mod.Ast, before: []const Scope, after: []const Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), trigger_scope: ScopeId, trigger_parent: ScopeId, actor: Actor) Error!void {
        if (!self.enabled) return;
        if (before.len > after.len or trigger_scope.isNone() or trigger_scope.toIndex() >= before.len or trigger_parent.isNone() or trigger_parent.toIndex() >= after.len) return error.InvalidScope;
        const owner = try ownerAt(tree, owners, trigger_scope);
        const parent = try ownerAt(tree, owners, trigger_parent);
        var count: usize = 0;
        for (before, after[0..before.len]) |left, right| if (!sameFrame(left, right)) {
            count += 1;
        };
        try self.events.ensureUnusedCapacity(a, count);
        for (before, after[0..before.len], 0..) |left, right, raw| {
            if (sameFrame(left, right)) continue;
            self.events.appendAssumeCapacity(.{ .kind = .frame, .scope = @fromBackingInt(@as(u32, @intCast(raw))), .before = left, .after = right, .owner_before = owner, .owner_after = owner, .trigger_scope = trigger_scope, .trigger_parent = trigger_parent, .parent_owner = parent, .actor = actor });
        }
    }

    /// Record a prepared flag update on one actual owned frame before the
    /// caller publishes it. Parent/kind/count changes use their own producers.
    pub fn recordOwnedFrame(self: *Recorder, a: std.mem.Allocator, tree: *const ast_mod.Ast, current: []const Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32), scope: ScopeId, after: Scope, actor: Actor) Error!void {
        if (!self.enabled) return;
        if (scope.isNone() or scope.toIndex() >= current.len or after.parent.isNone() or after.parent.toIndex() >= current.len) return error.InvalidScope;
        const before = current[scope.toIndex()];
        if (before.parent != after.parent or before.kind != after.kind or before.symbol_count != after.symbol_count or
            (before.is_strict and !after.is_strict) or
            (before.subtree_has_direct_eval and !after.subtree_has_direct_eval) or
            (before.subtree_has_with and !after.subtree_has_with)) return error.InvalidHistory;
        if (sameFrame(before, after)) return;
        const owner = (try ownerAt(tree, owners, scope)) orelse return error.InvalidNode;
        const parent = try ownerAt(tree, owners, after.parent);
        try self.events.append(a, .{ .kind = .frame, .scope = scope, .before = before, .after = after, .owner_before = owner, .owner_after = owner, .trigger_scope = scope, .trigger_parent = after.parent, .parent_owner = parent, .actor = actor });
    }

    /// Record a known scope-owner edge mutation at its actual producer, before
    /// changing the map. A later final-map scan is never used to create events.
    pub fn recordOwner(self: *Recorder, a: std.mem.Allocator, tree: *const ast_mod.Ast, scope: ScopeId, frame: Scope, before: NodeIndex, after: NodeIndex, actor: Actor) Error!void {
        if (!self.enabled or before == after) return;
        const after_owner = try Owner.capture(tree, after);
        try self.events.append(a, .{ .kind = .owner, .scope = scope, .before = frame, .after = frame, .owner_before = try Owner.capture(tree, before), .owner_after = after_owner, .owner_edges = if (after_owner) |h| try captureSourceEdges(tree, h) else .{}, .actor = actor });
    }
};

fn ownerAt(tree: *const ast_mod.Ast, owners: *const std.AutoHashMapUnmanaged(u32, u32), scope: ScopeId) Error!?Owner {
    var entries = owners.iterator();
    var selected: ?u32 = null;
    while (entries.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(scope)) continue;
        // Multiple actual aliases may describe one frame. Select a stable
        // actual map edge solely by NodeIndex; it does not select a SymbolId.
        if (selected == null or entry.key_ptr.* < selected.?) selected = entry.key_ptr.*;
    }
    return if (selected) |raw| try Owner.capture(tree, @fromBackingInt(raw)) else null;
}

/// Permission is supplied only after the actual runtime Target has validated.
/// It is not an arbitrary list of virtual scopes.
pub const RuntimePermission = struct {
    module_index: u32,
    wrapper_scope: ScopeId,
    program_scope: ScopeId,
};

pub const Index = struct {
    history: *const History,
    offsets: []usize,
    event_indices: []u32,
    class_key_read_membership: []bool = &.{},
    valid: bool,

    pub fn deinit(self: *Index, a: std.mem.Allocator) void {
        a.free(self.offsets);
        a.free(self.event_indices);
        a.free(self.class_key_read_membership);
    }

    /// Epoch is the number of already-published events at the producer point.
    /// One graph replay plus binary lookup avoids replaying history per leaf.
    pub fn frameAt(self: *const Index, scope: ScopeId, epoch: u32) ?Scope {
        if (!self.valid or scope.isNone() or scope.toIndex() + 1 >= self.offsets.len or epoch > self.history.events.len) return null;
        const raw = scope.toIndex();
        const indices = self.event_indices[self.offsets[raw]..self.offsets[raw + 1]];
        var left: usize = 0;
        var right = indices.len;
        while (left < right) {
            const middle = left + (right - left) / 2;
            if (indices[middle] < epoch) left = middle + 1 else right = middle;
        }
        if (left != 0) return self.history.events[indices[left - 1]].after;
        if (raw >= self.history.source_scopes.len) return null;
        return self.history.source_scopes[raw];
    }
};

fn frameValid(scopes: []const Scope, raw: usize) bool {
    if (raw >= scopes.len) return false;
    var cursor = scopes[raw].parent;
    var fuel = scopes.len + 1;
    while (!cursor.isNone() and fuel > 0) : (fuel -= 1) {
        if (cursor.toIndex() >= scopes.len or cursor.toIndex() == raw) return false;
        cursor = scopes[cursor.toIndex()].parent;
    }
    return fuel != 0;
}

fn ownerValid(tree: *const ast_mod.Ast, owner: Owner) bool {
    if (owner.node.isNone() or @backingInt(owner.node) >= tree.nodes.items.len or owner.span.start > owner.span.end) return false;
    // The historical payload may subsequently be rewritten in-place. Its map
    // edge is replayed by exact NodeIndex/ScopeId; final active owner syntax is
    // independently audited by Exact on the actual current AST.
    return switch (ast_mod.Node.Tag.dataKind(owner.tag)) {
        .extra, .list, .binary, .ternary, .unary => true,
        .leaf => owner.tag == .empty_statement or owner.tag == .binding_identifier or owner.tag == .identifier_reference or owner.tag == .assignment_target_identifier or owner.tag == .jsx_identifier,
    };
}

fn matchesOwnerEdge(owners: *const std.AutoHashMapUnmanaged(u32, u32), scope: ScopeId, witness: ?Owner) bool {
    if (witness) |owner| return owners.get(@backingInt(owner.node)) == @as(?u32, @backingInt(scope));
    var values = owners.valueIterator();
    while (values.next()) |value| if (value.* == @backingInt(scope)) return false;
    return true;
}

pub fn validateAndIndex(
    a: std.mem.Allocator,
    tree: *const ast_mod.Ast,
    current_scopes: []const Scope,
    current_owners: *const std.AutoHashMapUnmanaged(u32, u32),
    history: *const History,
    runtime: ?RuntimePermission,
) std.mem.Allocator.Error!Index {
    const offsets = try a.alloc(usize, current_scopes.len + 1);
    errdefer a.free(offsets);
    @memset(offsets, 0);
    const indices = try a.alloc(u32, history.events.len);
    errdefer a.free(indices);
    const key_membership = try a.alloc(bool, history.source_class_keys.len);
    errdefer a.free(key_membership);
    @memset(key_membership, false);
    var result: Index = .{ .history = history, .offsets = offsets, .event_indices = indices, .class_key_read_membership = key_membership, .valid = false };
    if (history.source_scopes.len == 0) {
        result.valid = history.source_owners.len == 0 and history.source_initializers.len == 0 and history.source_computed_awaits.len == 0 and history.worklet_class_creators.len == 0 and history.lowered_worklet_classes.len == 0 and history.source_class_keys.len == 0 and history.source_dropped_statements.len == 0 and history.source_drop_edges.len == 0 and history.events.len == 0;
        return result;
    }
    if (history.source_scopes.len > current_scopes.len) return result;
    var frames: std.ArrayList(Scope) = .empty;
    defer frames.deinit(a);
    try frames.ensureTotalCapacity(a, current_scopes.len);
    frames.appendSliceAssumeCapacity(history.source_scopes);
    for (frames.items, 0..) |_, raw| if (!frameValid(frames.items, raw)) return result;
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(a);
    for (history.source_owners) |binding| {
        if (binding.scope.isNone() or binding.scope.toIndex() >= frames.items.len or !ownerValid(tree, binding.owner) or owners.contains(@backingInt(binding.owner.node))) return result;
        inline for (.{ binding.edges.parameters, binding.edges.body, binding.edges.heritage }) |node| if (!node.isNone() and @backingInt(node) >= tree.nodes.items.len) return result;
        try owners.put(a, @backingInt(binding.owner.node), @backingInt(binding.scope));
    }
    for (history.source_initializers) |entry| {
        if (entry.scope.isNone() or entry.scope.toIndex() >= frames.items.len or frames.items[entry.scope.toIndex()].kind != .class_body or
            owners.get(@backingInt(entry.class_owner.node)) != @as(?u32, @backingInt(entry.scope)) or
            (entry.class_owner.tag != .class_declaration and entry.class_owner.tag != .class_expression) or
            (entry.field.tag != .property_definition and entry.field.tag != .accessor_property) or
            (entry.leaf.tag != .identifier_reference and entry.leaf.tag != .assignment_target_identifier and entry.leaf.tag != .jsx_identifier) or
            !ownerValid(tree, entry.field) or !ownerValid(tree, entry.leaf) or !ownerValid(tree, entry.initializer)) return result;
    }
    for (history.source_computed_awaits) |entry| {
        if (entry.scope.isNone() or entry.scope.toIndex() >= frames.items.len or frames.items[entry.scope.toIndex()].kind != .class_body or owners.get(@backingInt(entry.class_owner.node)) != @as(?u32, @backingInt(entry.scope)) or
            entry.key.tag != .computed_property_key or entry.await_node.tag != .await_expression or entry.leaf.tag != .identifier_reference or entry.key.words[0] != @backingInt(entry.await_node.node)) return result;
        inline for (.{ entry.declaration, entry.key, entry.await_node, entry.leaf }) |owner| if (!ownerValid(tree, owner)) return result;
    }
    var key_reads: std.AutoHashMapUnmanaged(u32, []const NodeIndex) = .empty;
    defer {
        var values = key_reads.valueIterator();
        while (values.next()) |reads| a.free(reads.*);
        key_reads.deinit(a);
    }
    for (history.source_class_keys, 0..) |entry, key_index| {
        if (entry.scope.isNone() or entry.scope.toIndex() >= frames.items.len or frames.items[entry.scope.toIndex()].kind != .class_body or
            owners.get(@backingInt(entry.class_owner.node)) != @as(?u32, @backingInt(entry.scope)) or
            entry.body.tag != .class_body or entry.key.tag != .computed_property_key or entry.leaf.tag != .identifier_reference or
            (entry.member.tag != .method_definition and entry.member.tag != .property_definition and entry.member.tag != .accessor_property)) return result;
        inline for (.{ entry.class_owner, entry.body, entry.member, entry.key, entry.leaf }) |owner| if (!ownerValid(tree, owner)) return result;
        if (entry.body.words[0] > tree.extra_data.items.len or entry.body.words[1] > tree.extra_data.items.len - entry.body.words[0] or
            entry.member_slot < entry.body.words[0] or entry.member_slot - entry.body.words[0] >= entry.body.words[1]) return result;
        if (tree.extra_data.items[entry.member_slot] == @backingInt(entry.member.node) and entry.member.words[0] < tree.extra_data.items.len and
            tree.extra_data.items[entry.member.words[0]] == @backingInt(entry.key.node) and entry.key.words[0] < tree.nodes.items.len)
        {
            const gop = try key_reads.getOrPut(a, @backingInt(entry.key.node));
            if (!gop.found_existing) {
                errdefer _ = key_reads.remove(@backingInt(entry.key.node));
                gop.value_ptr.* = try @import("reference_walk.zig").collectIdentifierReferences(a, tree, @fromBackingInt(entry.key.words[0]));
            }
            var matches: usize = 0;
            for (gop.value_ptr.*) |read| if (read == entry.leaf.node) {
                matches += 1;
            };
            key_membership[key_index] = matches == 1;
        }
        var matched: usize = 0;
        for (history.source_owners) |binding| if (binding.scope == entry.scope and std.meta.eql(binding.owner, entry.class_owner) and binding.edges.body == entry.body.node) {
            matched += 1;
        };
        if (matched != 1) return result;
    }
    for (history.events) |event| {
        if (event.scope.isNone()) return result;
        inline for (.{ event.owner_edges.parameters, event.owner_edges.body, event.owner_edges.heritage }) |node| if (!node.isNone() and @backingInt(node) >= tree.nodes.items.len) return result;
        switch (event.actor.role) {
            .editor => if (event.actor.module_index != null) return result,
            .cjs_wrapper => {
                const permission = runtime orelse return result;
                if (event.actor.module_index != permission.module_index) return result;
                switch (event.kind) {
                    .birth => if (event.scope != permission.wrapper_scope) return result,
                    .frame => if (event.scope != permission.program_scope or event.after.parent != permission.wrapper_scope) return result,
                    .owner => {},
                }
            },
        }
        if (event.owner_before) |owner| if (!ownerValid(tree, owner)) return result;
        if (event.owner_after) |owner| if (!ownerValid(tree, owner)) return result;
        if (event.parent_owner) |owner| if (!ownerValid(tree, owner)) return result;
        const raw = event.scope.toIndex();
        switch (event.kind) {
            .birth => {
                if (event.before != null or raw != frames.items.len or raw >= current_scopes.len or event.owner_before != null) return result;
                if (event.after.parent.isNone()) {
                    const permission = runtime orelse return result;
                    if (event.actor.role != .cjs_wrapper or event.scope != permission.wrapper_scope) return result;
                } else if (event.after.parent.toIndex() >= frames.items.len) return result;
                frames.appendAssumeCapacity(event.after);
                if (!frameValid(frames.items, raw)) return result;
                if (event.owner_after) |owner| {
                    const slot = try owners.getOrPut(a, @backingInt(owner.node));
                    if (slot.found_existing) return result;
                    slot.value_ptr.* = raw;
                }
            },
            .frame => {
                const before = event.before orelse return result;
                if (raw >= frames.items.len or !sameFrame(before, frames.items[raw]) or before.kind != event.after.kind or
                    event.trigger_scope.isNone() or event.trigger_scope.toIndex() >= frames.items.len or
                    event.trigger_parent.isNone() or event.trigger_parent.toIndex() >= frames.items.len) return result;
                if (!std.meta.eql(event.owner_before, event.owner_after) or
                    !matchesOwnerEdge(&owners, event.trigger_scope, event.owner_before) or
                    !matchesOwnerEdge(&owners, event.trigger_parent, event.parent_owner)) return result;
                if (before.parent != event.after.parent and (event.scope != event.trigger_scope or event.after.parent != event.trigger_parent)) return result;
                if ((before.is_strict and !event.after.is_strict) or
                    (before.subtree_has_direct_eval and !event.after.subtree_has_direct_eval) or
                    (before.subtree_has_with and !event.after.subtree_has_with)) return result;
                frames.items[raw] = event.after;
                if (!frameValid(frames.items, raw)) return result;
            },
            .owner => {
                const before = event.before orelse return result;
                if (raw >= frames.items.len or !sameFrame(before, frames.items[raw]) or !sameFrame(before, event.after) or
                    (event.owner_before == null and event.owner_after == null)) return result;
                if (event.owner_before) |owner| {
                    const key = @backingInt(owner.node);
                    if (owners.get(key) != raw) return result;
                    _ = owners.remove(key);
                }
                if (event.owner_after) |owner| {
                    const key = @backingInt(owner.node);
                    if (owners.get(key)) |existing| {
                        if (existing != raw) return result;
                    } else try owners.put(a, key, raw);
                }
            },
        }
        offsets[raw + 1] += 1;
    }
    if (frames.items.len != current_scopes.len or owners.count() != current_owners.count()) return result;
    for (frames.items, current_scopes) |before, actual| if (!sameFrame(before, actual)) return result;
    var owner_rows = owners.iterator();
    while (owner_rows.next()) |entry| if (current_owners.get(entry.key_ptr.*) != entry.value_ptr.*) return result;
    for (1..offsets.len) |i| offsets[i] += offsets[i - 1];
    const writes = try a.dupe(usize, offsets[0..current_scopes.len]);
    defer a.free(writes);
    for (history.events, 0..) |event, epoch| {
        const raw = event.scope.toIndex();
        indices[writes[raw]] = @intCast(epoch);
        writes[raw] += 1;
    }
    result.valid = true;
    if (!try validateDroppedStatements(a, tree, &result)) result.valid = false;
    return result;
}

fn validateDroppedStatements(a: std.mem.Allocator, tree: *const ast_mod.Ast, index: *const Index) std.mem.Allocator.Error!bool {
    const Drop = @import("source_drop_registry.zig");
    var cursor: usize = 0;
    var roots: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer roots.deinit(a);
    for (index.history.source_dropped_statements) |statement| {
        if (statement.entry_epoch > statement.selection_epoch or statement.selection_epoch > index.history.events.len or
            statement.edge_start != cursor or statement.edge_len > index.history.source_drop_edges.len - cursor) return false;
        const scope = index.frameAt(statement.execution_scope, statement.selection_epoch) orelse return false;
        if (!sameFrame(scope, statement.execution_frame)) return false;
        const root = try roots.getOrPut(a, @backingInt(statement.source.index));
        if (root.found_existing) return false;
        if (!try Drop.validatesStatement(a, tree, statement, index.history.source_drop_edges[cursor..][0..statement.edge_len])) return false;
        cursor += statement.edge_len;
    }
    return cursor == index.history.source_drop_edges.len;
}
