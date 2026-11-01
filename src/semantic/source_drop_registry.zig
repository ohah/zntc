//! Immutable active payloads and child edges of an explicitly selected drop.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Scope = @import("scope.zig");
const max_extra_words = maximum: {
    @setEvalBranchQuota(20000);
    var maximum: usize = 0;
    for (std.enums.values(Ast.Node.Tag)) |tag| {
        maximum = @max(maximum, tag.runtimeExtraWords() orelse 0);
    }
    break :maximum maximum;
};

pub const Node = struct {
    index: Ast.NodeIndex,
    tag: Ast.Node.Tag,
    span: @import("../lexer/token.zig").Span,
    data: [12]u8 = @splat(0),
    /// Initial actual attached SID, retained after the output leaf retires.
    source_symbol: ?u32 = null,
    extra_len: u8 = 0,
    extra: [max_extra_words]u32 = @splat(0),

    pub fn capture(tree: *const Ast.Ast, index: Ast.NodeIndex) ?Node {
        if (index.isNone() or @backingInt(index) >= tree.nodes.items.len) return null;
        const node = tree.getNode(index);
        var result: Node = .{ .index = index, .tag = node.tag, .span = node.span };
        const width = Ast.Node.Tag.dataWidth(node.tag);
        @memcpy(result.data[0..width], std.mem.asBytes(&node.data)[0..width]);
        if (node.tag.runtimeExtraWords()) |count| {
            if (node.data.extra > tree.extra_data.items.len or count > tree.extra_data.items.len - node.data.extra) return null;
            result.extra_len = count;
            @memcpy(result.extra[0..count], tree.extra_data.items[node.data.extra..][0..count]);
        }
        return result;
    }

    pub fn captureSource(tree: *const Ast.Ast, ids: []const ?u32, index: Ast.NodeIndex) ?Node {
        var result = capture(tree, index) orelse return null;
        if (@backingInt(index) >= ids.len) return null;
        result.source_symbol = ids[@backingInt(index)];
        return result;
    }

    pub fn matches(self: Node, tree: *const Ast.Ast) bool {
        const current = capture(tree, self.index) orelse return false;
        // The initial SID is an immutable source fact, not an output ID.
        // Declaration retirement checks it separately against its witness.
        var payload = self;
        payload.source_symbol = null;
        return std.meta.eql(payload, current);
    }
};

pub const Edge = struct {
    parent: Node,
    child: ?Node,
    ordinal: u32,
    child_count: u32,
};

pub const Action = enum { label, console, debugger };

pub const Statement = struct {
    action: Action,
    source: Node,
    selected: Node,
    /// Epoch zero is analyzer birth; entry_epoch is the actual transformer input.
    entry_epoch: u32,
    selection_epoch: u32,
    execution_scope: Scope.ScopeId,
    execution_frame: Scope.Scope,
    edge_start: u32,
    edge_len: u32,
};

pub fn validatesEdge(tree: *const Ast.Ast, edge: Edge) bool {
    if (!edge.parent.matches(tree) or edge.ordinal >= edge.child_count) return false;
    var children = @import("../parser/ast_walk.zig").children(tree, tree.getNode(edge.parent.index));
    var count: u32 = 0;
    var found = false;
    while (children.next()) |child| : (count += 1) {
        if (count != edge.ordinal) continue;
        if (edge.child) |expected| {
            if (child != expected.index or !expected.matches(tree)) return false;
        } else if (!child.isNone()) return false;
        found = true;
    }
    return found and count == edge.child_count;
}

pub fn validatesEdges(a: std.mem.Allocator, tree: *const Ast.Ast, edges: []const Edge) std.mem.Allocator.Error!bool {
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(a);
    var cursor: usize = 0;
    while (cursor < edges.len) {
        const first = edges[cursor];
        if (first.ordinal != 0 or first.child_count == 0 or first.child_count > edges.len - cursor or !first.parent.matches(tree)) return false;
        const entry = try seen.getOrPut(a, @backingInt(first.parent.index));
        if (entry.found_existing) return false;
        var children = @import("../parser/ast_walk.zig").children(tree, tree.getNode(first.parent.index));
        for (edges[cursor..][0..first.child_count], 0..) |edge, ordinal| {
            if (!std.meta.eql(edge.parent, first.parent) or edge.ordinal != ordinal or edge.child_count != first.child_count) return false;
            const child = children.next() orelse return false;
            if (edge.child) |expected| {
                if (child != expected.index or !expected.matches(tree)) return false;
            } else if (!child.isNone()) return false;
        }
        if (children.next() != null) return false;
        cursor += first.child_count;
    }
    return true;
}

pub fn validatesStatement(a: std.mem.Allocator, tree: *const Ast.Ast, statement: Statement, edges: []const Edge) std.mem.Allocator.Error!bool {
    if (!statement.source.matches(tree) or !statement.selected.matches(tree) or !std.meta.eql(statement.source, statement.selected)) return false;
    switch (statement.action) {
        .label => if (statement.source.tag != .labeled_statement) return false,
        .console => if (statement.source.tag != .expression_statement or !@import("../transformer/drop_scan.zig").isConsoleCallInAst(tree, tree.getNode(statement.source.index))) return false,
        .debugger => if (statement.source.tag != .debugger_statement) return false,
    }
    if (!try validatesEdges(a, tree, edges)) return false;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, tree, statement.source.index);
    defer a.free(nodes);
    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable.deinit(a);
    var parents: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer parents.deinit(a);
    for (nodes) |raw| try reachable.put(a, raw, {});
    for (edges) |edge| if (edge.ordinal == 0) {
        if (!reachable.contains(@backingInt(edge.parent.index))) return false;
        try parents.put(a, @backingInt(edge.parent.index), {});
    };
    for (nodes) |raw| {
        var children = @import("../parser/ast_walk.zig").children(tree, tree.nodes.items[raw]);
        if (children.next() != null and !parents.contains(raw)) return false;
    }
    return true;
}

/// Every occurrence must agree with the source SID captured at birth.
pub fn hasSourceBinding(edges: []const Edge, node: Ast.NodeIndex, sid: u32) bool {
    var found = false;
    for (edges) |edge| {
        if (edge.parent.index == node) {
            if (edge.parent.source_symbol != sid) return false;
            found = true;
        }
        if (edge.child) |child| if (child.index == node) {
            if (child.source_symbol != sid) return false;
            found = true;
        };
    }
    return found;
}
