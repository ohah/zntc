//! Ephemeral placement authority for exact native static-field initializer uses.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const sym = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const module = @import("../bundler/module.zig");
const coords = @import("../semantic/statement_coordinates.zig");
const Publication = @import("transformer.zig").StatementPublication;
pub const Error = std.mem.Allocator.Error || error{InvalidClassInitializerPublication};
pub const SourceBlock = struct { node: ast.NodeIndex, scope: ScopeId, index: u32 };
pub const SourceMethod = struct { node: ast.NodeIndex, key: ast.NodeIndex, index: u32, scope: ScopeId, decorator: sym.Reference };
pub const Source = struct {
    ast: *const ast.Ast,
    owner: module.SemanticOwnerToken,
    class: ast.NodeIndex,
    class_scope: ScopeId,
    outer_scope: ScopeId,
    binding: ast.NodeIndex,
    class_id: sym.SymbolId,
    body: ast.NodeIndex,
    members_len: u32,
    field: ast.NodeIndex,
    field_index: u32,
    key: ast.NodeIndex,
    init: ast.NodeIndex,
    read: sym.Reference,
    storage: ScopeId,
    blocks: []const SourceBlock,
    methods: []const SourceMethod,
};
pub const Frame = struct {
    source: Source,
    output_ast: *const ast.Ast,
    block: ast.NodeIndex,
    body: ast.NodeIndex,
    scope: ScopeId,
    statement: ast.NodeIndex = .none,
    value: ast.NodeIndex = .none,
    key: ast.NodeIndex = .none,
    reference: ast.NodeIndex = .none,
    prior: coords.Context,
    published: ?coords.Context = null,
    class_owner: ast.NodeIndex = .none,
    published_root: ast.NodeIndex = .none,
    published_top: ast.NodeIndex = .none,
};
fn invalid() Error {
    return error.InvalidClassInitializerPublication;
}
fn context(row: sym.Reference) coords.Context {
    return .{ .stmt_idx = row.stmt_idx, .scope_stmt_idx = row.scope_stmt_idx };
}

pub fn activate(self: anytype, source: Source, owner: module.SemanticOwnerToken) Error!void {
    if (!self.semantic_edit_enabled or source.owner == .unassigned or source.owner != owner or source.ast != self.semantic_source_ast or
        self.class_initializer_source != null or self.class_initializer_frames.items.len != 0) return invalid();
    self.class_initializer_source = source;
    self.class_initializer_domain = self.ast;
}

fn validSource(self: anytype, source: Source) bool {
    const registered = self.class_initializer_source orelse return false;
    if (source.owner == .unassigned or !std.meta.eql(source, registered) or
        source.ast != self.semantic_source_ast or self.class_initializer_domain != self.ast) return false;
    const editor = if (self.semantic_editor) |*value| value else return false;
    if (editor.ast != self.ast or source.class_scope.isNone() or source.class_scope.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[source.class_scope.toIndex()].kind != .class_body or editor.scopes.items[source.class_scope.toIndex()].parent != source.outer_scope or
        @backingInt(source.read.symbol_id) >= editor.symbols.items.len or editor.symbols.items[@backingInt(source.read.symbol_id)].scope_id != source.storage or
        self.getSymbolIdAt(source.binding) != @as(?u32, @backingInt(source.class_id))) return false;
    const node = source.ast.getNode(source.class);
    if (node.tag != .class_declaration or source.ast.readExtraNode(node.data.extra, ast.ClassExtra.body) != source.body) return false;
    const list = source.ast.getNode(source.body).data.list;
    if (list.len != source.members_len or source.field_index >= list.len or source.ast.extra_data.items[list.start + source.field_index] != @backingInt(source.field)) return false;
    const field = source.ast.getNode(source.field);
    return field.tag == .property_definition and source.ast.readExtraNode(field.data.extra, ast.PropertyExtra.key) == source.key and
        source.ast.readExtraNode(field.data.extra, ast.PropertyExtra.init) == source.init;
}

pub fn begin(self: anytype, class: ast.NodeIndex, field: ast.NodeIndex, init: ast.NodeIndex, class_scope: ScopeId, block: ast.NodeIndex, body: ast.NodeIndex, scope: ScopeId) Error!?Frame {
    const source = self.class_initializer_source orelse return null;
    if (source.class != class) return null;
    if (!validSource(self, source) or source.field != field or source.init != init or source.class_scope != class_scope or
        self.outputOwnedScope(class) != class_scope or @backingInt(block) < self.parser_node_count or @backingInt(body) < self.parser_node_count or
        self.ast.getNode(block).tag != .static_block or self.ast.getNode(block).data.unary.operand != body or self.ast.getNode(body).tag != .block_statement or
        self.outputOwnedScope(block) != scope or self.outputOwnedScope(body) != scope) return invalid();
    const editor = &self.semantic_editor.?;
    if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[scope.toIndex()].kind != .class_static_block or
        editor.scopes.items[scope.toIndex()].parent != class_scope or !editor.scopes.items[scope.toIndex()].is_strict) return invalid();
    var found: ?sym.Reference = null;
    for (editor.references.items) |row| if (row.node_index == source.read.node_index) {
        if (found != null or row.symbol_id != source.read.symbol_id or row.scope_id != class_scope or !std.meta.eql(row.flags, source.read.flags)) return invalid();
        found = row;
    };
    const row = found orelse return invalid();
    if (self.getSymbolIdAt(row.node_index) != @as(?u32, @backingInt(row.symbol_id))) return invalid();
    return .{ .source = source, .output_ast = self.ast, .block = block, .body = body, .scope = scope, .prior = context(row) };
}

fn find(self: anytype, frame: Frame) Error!usize {
    if (!validSource(self, frame.source) or frame.output_ast != self.ast or frame.reference.isNone() or
        self.getSymbolIdAt(frame.reference) != @as(?u32, @backingInt(frame.source.read.symbol_id))) return invalid();
    var found: ?usize = null;
    for (self.semantic_editor.?.references.items, 0..) |row, index| if (row.node_index == frame.reference) {
        if (found != null or row.symbol_id != frame.source.read.symbol_id or row.scope_id != frame.scope or !std.meta.eql(row.flags, frame.source.read.flags)) return invalid();
        found = index;
    };
    return found orelse invalid();
}

fn validateEdges(self: anytype, frame: Frame) Error!void {
    if (!validSource(self, frame.source) or frame.output_ast != self.ast or self.ast.getNode(frame.block).tag != .static_block or
        self.ast.getNode(frame.block).data.unary.operand != frame.body or self.outputOwnedScope(frame.block) != frame.scope or self.outputOwnedScope(frame.body) != frame.scope) return invalid();
    if (frame.scope.isNone() or frame.scope.toIndex() >= self.semantic_editor.?.scopes.items.len) return invalid();
    const environment = self.semantic_editor.?.scopes.items[frame.scope.toIndex()];
    if (environment.kind != .class_static_block or environment.parent != frame.source.class_scope or !environment.is_strict) return invalid();
    try validateValueEdges(self, frame);
}

fn validateValueEdges(self: anytype, frame: Frame) Error!void {
    const body = self.ast.getNode(frame.body);
    if (body.tag != .block_statement or body.data.list.len != 1 or self.ast.extra_data.items[body.data.list.start] != @backingInt(frame.statement)) return invalid();
    const stmt = self.ast.getNode(frame.statement);
    if (stmt.tag != .expression_statement) return invalid();
    const assignment = self.ast.getNode(stmt.data.unary.operand);
    if (assignment.tag != .assignment_expression or assignment.data.binary.right != frame.value or assignment.data.binary.flags != 0) return invalid();
    const target = self.ast.getNode(assignment.data.binary.left);
    if (target.tag != .static_member_expression or self.ast.readExtraNode(target.data.extra, 1) != frame.key or
        self.ast.getNode(self.ast.readExtraNode(target.data.extra, 0)).tag != .this_expression or frame.key != frame.source.key) return invalid();
    const call = self.ast.getNode(frame.value);
    const old = frame.source.ast.getNode(frame.source.init);
    if (call.tag != .call_expression or self.ast.readExtra(call.data.extra, 3) != 0 or self.ast.readExtra(call.data.extra, 2) != frame.source.ast.readExtra(old.data.extra, 2)) return invalid();
    const member = self.ast.getNode(self.ast.readExtraNode(call.data.extra, 0));
    const old_member = frame.source.ast.getNode(frame.source.ast.readExtraNode(old.data.extra, 0));
    if (member.tag != .static_member_expression or self.ast.readExtra(member.data.extra, 2) != 0 or self.ast.readExtraNode(member.data.extra, 0) != frame.reference or
        self.ast.readExtraNode(member.data.extra, 1) != frame.source.ast.readExtraNode(old_member.data.extra, 1)) return invalid();
    const args = self.ast.readExtra(call.data.extra, 1);
    const old_args = frame.source.ast.readExtra(old.data.extra, 1);
    for (0..self.ast.readExtra(call.data.extra, 2)) |index| if (self.ast.extra_data.items[args + index] != frame.source.ast.extra_data.items[old_args + index]) return invalid();
}

/// The real block body edge now exists. Capture its exact returned reference;
/// only a recorded source-copy origin may explain a fresh expression node.
pub fn seal(self: anytype, pending: Frame, key: ast.NodeIndex, value: ast.NodeIndex, statement: ast.NodeIndex) Error!void {
    var frame = pending;
    frame.key = key;
    frame.value = value;
    frame.statement = statement;
    const call = self.ast.getNode(value);
    if (call.tag != .call_expression) return invalid();
    const callee = self.ast.getNode(self.ast.readExtraNode(call.data.extra, 0));
    if (callee.tag != .static_member_expression) return invalid();
    frame.reference = self.ast.readExtraNode(callee.data.extra, 0);
    var original = @backingInt(frame.reference);
    var hops: usize = 0;
    while (original != @backingInt(frame.source.read.node_index)) : (hops += 1) {
        if (hops >= self.ast.nodes.items.len) return invalid();
        original = self.reference_origin_map.get(original) orelse return invalid();
    }
    try validateEdges(self, frame);
    const index = try find(self, frame);
    frame.prior = context(self.semantic_editor.?.references.items[index]);
    for (self.class_initializer_frames.items) |previous| if (previous.source.field == frame.source.field) return invalid();
    try self.class_initializer_frames.append(self.allocator, frame);
}

fn parents(self: anytype, root: ast.NodeIndex) Error!std.AutoHashMapUnmanaged(u32, u32) {
    var result: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    errdefer result.deinit(self.allocator);
    const nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(nodes);
    for (nodes) |raw| {
        var children = walk.children(self.ast, self.ast.nodes.items[raw]);
        while (children.next()) |child| {
            const slot = try result.getOrPut(self.allocator, @backingInt(child));
            if (slot.found_existing and slot.value_ptr.* != raw) return invalid();
            slot.value_ptr.* = raw;
        }
    }
    return result;
}
fn classOwner(self: anytype, frame: Frame, map: *const std.AutoHashMapUnmanaged(u32, u32)) Error!ast.NodeIndex {
    const body_raw = map.get(@backingInt(frame.block)) orelse return invalid();
    const class_raw = map.get(body_raw) orelse return invalid();
    const owner: ast.NodeIndex = @fromBackingInt(class_raw);
    const node = self.ast.getNode(owner);
    if ((node.tag != .class_declaration and node.tag != .class_expression) or self.outputOwnedScope(owner) != frame.source.class_scope or self.ast.readExtraNode(node.data.extra, ast.ClassExtra.body) != @as(ast.NodeIndex, @fromBackingInt(body_raw))) return invalid();
    const list = self.ast.getNode(@fromBackingInt(body_raw)).data.list;
    if (list.len != frame.source.members_len or frame.source.field_index >= list.len or self.ast.extra_data.items[list.start + frame.source.field_index] != @backingInt(frame.block)) return invalid();
    for (frame.source.blocks) |block| {
        if (block.index >= list.len) return invalid();
        const actual: ast.NodeIndex = @fromBackingInt(self.ast.extra_data.items[list.start + block.index]);
        const value = self.ast.getNode(actual);
        if (value.tag != .static_block or self.outputOwnedScope(actual) != block.scope or self.outputOwnedScope(value.data.unary.operand) != block.scope) return invalid();
        if (actual != block.node and self.scope_owner_origins.get(@backingInt(actual)) != @backingInt(block.node)) return invalid();
    }
    return owner;
}

/// Called after real program assembly, before any positions-only projectors.
/// All validation and allocations finish before either rows or ledger change.
pub fn publishChecked(self: anytype, root: ast.NodeIndex) Error!void {
    if (self.class_initializer_frames.items.len == 0) return;
    const contexts = coords.collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(),
    };
    defer self.allocator.free(contexts);
    var map = try parents(self, root);
    defer map.deinit(self.allocator);
    const Update = struct { index: usize, frame: *Frame, value: coords.Context, owner: ast.NodeIndex, top: ast.NodeIndex };
    var updates: std.ArrayList(Update) = .empty;
    defer updates.deinit(self.allocator);
    for (self.class_initializer_frames.items) |*frame| {
        try validateEdges(self, frame.*);
        const owner = try classOwner(self, frame.*, &map);
        const index = try find(self, frame.*);
        const row = self.semantic_editor.?.references.items[index];
        const prior = frame.published orelse frame.prior;
        if (!std.meta.eql(context(row), prior)) return invalid();
        const actual = contexts[@backingInt(frame.reference)] orelse return invalid();
        if (actual.stmt_idx == sym.Reference.NO_STMT or actual.scope_stmt_idx != 0) return invalid();
        const program = self.ast.getNode(root);
        if (program.tag != .program or actual.stmt_idx >= program.data.list.len) return invalid();
        try updates.append(self.allocator, .{ .index = index, .frame = frame, .value = actual, .owner = owner, .top = @fromBackingInt(self.ast.extra_data.items[program.data.list.start + actual.stmt_idx]) });
    }
    for (updates.items) |update| {
        self.semantic_editor.?.references.items[update.index].stmt_idx = update.value.stmt_idx;
        self.semantic_editor.?.references.items[update.index].scope_stmt_idx = update.value.scope_stmt_idx;
        update.frame.published = update.value;
        update.frame.class_owner = update.owner;
        update.frame.published_root = root;
        update.frame.published_top = update.top;
    }
}
pub fn publish(self: anytype, root: ast.NodeIndex) !void {
    publishChecked(self, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("class initializer publication rejected: {s}", .{@errorName(err)}),
    };
}

/// A stale row and stale publication cannot certify a subsequently edited AST.
pub fn validateCommitted(self: anytype, root: ast.NodeIndex) Error!void {
    if (self.class_initializer_frames.items.len == 0) return;
    const contexts = coords.collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(),
    };
    defer self.allocator.free(contexts);
    var map = try parents(self, root);
    defer map.deinit(self.allocator);
    for (self.class_initializer_frames.items) |frame| {
        try validateEdges(self, frame);
        if (frame.published_root != root or try classOwner(self, frame, &map) != frame.class_owner) return invalid();
        const known = frame.published orelse return invalid();
        const index = try find(self, frame);
        const actual = contexts[@backingInt(frame.reference)] orelse return invalid();
        if (!std.meta.eql(actual, known) or !std.meta.eql(context(self.semantic_editor.?.references.items[index]), known)) return invalid();
    }
}
pub fn agree(self: anytype, raw: u32, other: ?Publication, flags: sym.ReferenceFlags) @import("../semantic/editor.zig").Error!?Publication {
    var result = other;
    for (self.class_initializer_frames.items) |frame| {
        if (@backingInt(frame.reference) != raw) continue;
        const known = frame.published orelse return error.InvalidNode;
        validateEdges(self, frame) catch return error.InvalidNode;
        if (!std.meta.eql(flags, frame.source.read.flags)) return error.InvalidNode;
        const index = find(self, frame) catch return error.InvalidNode;
        if (!std.meta.eql(context(self.semantic_editor.?.references.items[index]), known)) return error.InvalidNode;
        const program = self.ast.getNode(frame.published_root);
        if (program.tag != .program or known.stmt_idx >= program.data.list.len or self.ast.extra_data.items[program.data.list.start + known.stmt_idx] != @backingInt(frame.published_top)) return error.InvalidNode;
        const value: Publication = .{ .symbol_id = frame.source.read.symbol_id, .scope = frame.scope, .stmt = known.stmt_idx, .scope_stmt = known.scope_stmt_idx };
        if (result) |previous| if (!std.meta.eql(previous, value)) return error.InvalidNode;
        result = value;
    }
    return result;
}

/// Read the actual post-finish semantic slices. Finishing moves the editor's
/// arrays; rebuilding an editor or trusting its emptied storage would certify
/// a different graph. This check never changes a row or chooses an identity.
pub fn validateFinished(self: anytype, semantic: *const module.ModuleSemanticData, root: ast.NodeIndex) Error!void {
    const source = self.class_initializer_source orelse return invalid();
    if (source.owner == .unassigned or source.owner != semantic.owner_token or source.ast != self.semantic_source_ast or
        self.class_initializer_domain != self.ast or self.class_initializer_frames.items.len != 1) return invalid();
    if (source.class_scope.isNone() or source.class_scope.toIndex() >= semantic.scopes.len or
        source.storage.isNone() or source.storage.toIndex() >= semantic.scopes.len or
        @backingInt(source.class_id) >= semantic.symbols.items.len or @backingInt(source.read.symbol_id) >= semantic.symbols.items.len or
        @backingInt(source.binding) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(source.binding)] != @as(u32, @intCast(@backingInt(source.class_id)))) return invalid();
    const class_scope = semantic.scopes[source.class_scope.toIndex()];
    if (class_scope.kind != .class_body or !class_scope.is_strict or class_scope.parent != source.outer_scope or
        semantic.symbols.items[@backingInt(source.class_id)].scope_id != source.outer_scope or
        semantic.symbols.items[@backingInt(source.read.symbol_id)].scope_id != source.storage or
        semantic.symbols.items[@backingInt(source.read.symbol_id)].kind != .variable_const) return invalid();
    const frame = self.class_initializer_frames.items[0];
    if (!std.meta.eql(frame.source, source) or frame.output_ast != self.ast or frame.published_root != root or frame.published == null or
        frame.scope.isNone() or frame.scope.toIndex() >= semantic.scopes.len or
        @backingInt(frame.reference) >= semantic.symbol_ids.len or semantic.symbol_ids[@backingInt(frame.reference)] != @as(u32, @intCast(@backingInt(source.read.symbol_id))) or
        semantic.scope_owner_map.get(@backingInt(frame.block)) != @backingInt(frame.scope) or
        semantic.scope_owner_map.get(@backingInt(frame.body)) != @backingInt(frame.scope)) return invalid();
    const environment = semantic.scopes[frame.scope.toIndex()];
    if (environment.kind != .class_static_block or !environment.is_strict or environment.parent != source.class_scope or
        self.ast.getNode(frame.block).tag != .static_block or self.ast.getNode(frame.block).data.unary.operand != frame.body) return invalid();
    try validateValueEdges(self, frame);
    const contexts = coords.collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(),
    };
    defer self.allocator.free(contexts);
    const actual = contexts[@backingInt(frame.reference)] orelse return invalid();
    if (!std.meta.eql(actual, frame.published.?) or actual.scope_stmt_idx != 0 or actual.stmt_idx == sym.Reference.NO_STMT) return invalid();
    var count: usize = 0;
    for (semantic.references) |row| {
        if (row.node_index != frame.reference) continue;
        if (row.symbol_id != source.read.symbol_id or row.scope_id != frame.scope or !std.meta.eql(row.flags, source.read.flags) or !std.meta.eql(context(row), actual)) return invalid();
        count += 1;
    }
    if (count != 1) return invalid();
    var map = try parents(self, root);
    defer map.deinit(self.allocator);
    const body_raw = map.get(@backingInt(frame.block)) orelse return invalid();
    const class_raw = map.get(body_raw) orelse return invalid();
    if (class_raw != @backingInt(frame.class_owner) or semantic.scope_owner_map.get(class_raw) != @backingInt(source.class_scope)) return invalid();
    const class = self.ast.nodes.items[class_raw];
    if (class.tag != .class_declaration or self.ast.readExtraNode(class.data.extra, ast.ClassExtra.body) != @as(ast.NodeIndex, @fromBackingInt(body_raw)) or
        self.ast.readExtraNode(class.data.extra, ast.ClassExtra.name) != source.binding or !self.ast.readExtraNode(class.data.extra, ast.ClassExtra.super).isNone()) return invalid();
    const body = self.ast.nodes.items[body_raw];
    if (body.tag != .class_body or body.data.list.len != source.members_len or
        self.ast.extra_data.items[body.data.list.start + source.field_index] != @backingInt(frame.block)) return invalid();
    for (source.methods) |method| {
        if (method.index >= body.data.list.len) return invalid();
        const node: ast.NodeIndex = @fromBackingInt(self.ast.extra_data.items[body.data.list.start + method.index]);
        const value = self.ast.getNode(node);
        if (value.tag != .method_definition or semantic.scope_owner_map.get(@backingInt(node)) != @backingInt(method.scope) or
            self.ast.readExtraNode(value.data.extra, ast.MethodExtra.key) != method.key or
            method.scope.isNone() or method.scope.toIndex() >= semantic.scopes.len or semantic.scopes[method.scope.toIndex()].parent != source.class_scope or
            (node != method.node and self.scope_owner_origins.get(@backingInt(node)) != @backingInt(method.node))) return invalid();
    }
    for (source.blocks) |block| {
        if (block.index >= body.data.list.len or block.scope.isNone() or block.scope.toIndex() >= semantic.scopes.len) return invalid();
        const source_environment = semantic.scopes[block.scope.toIndex()];
        if (source_environment.kind != .class_static_block or !source_environment.is_strict or source_environment.parent != source.class_scope) return invalid();
        const node: ast.NodeIndex = @fromBackingInt(self.ast.extra_data.items[body.data.list.start + block.index]);
        const value = self.ast.getNode(node);
        if (value.tag != .static_block or semantic.scope_owner_map.get(@backingInt(node)) != @backingInt(block.scope) or
            semantic.scope_owner_map.get(@backingInt(value.data.unary.operand)) != @backingInt(block.scope) or
            (node != block.node and self.scope_owner_origins.get(@backingInt(node)) != @backingInt(block.node))) return invalid();
    }
}
