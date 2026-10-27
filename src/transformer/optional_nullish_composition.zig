//! Exact creator authority for a bounded optional-member result consumed by ??.
//! No late identity recovery, coordinate repair, or scope selection is performed.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const module = @import("../bundler/module.zig");
const symbol = @import("../semantic/symbol.zig");
const coordinates = @import("../semantic/statement_coordinates.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast.NodeIndex;
const token = @import("../lexer/token.zig");
pub const Input = struct { node: NodeIndex, left: NodeIndex, right: NodeIndex, scope: ScopeId };
pub const Source = struct {
    ast: *const ast.Ast,
    output: ?*const ast.Ast = null,
    owner: module.SemanticOwnerToken = .unassigned,
    inputs: []const Input,
    late_names: bool,
    pub fn deinit(self: Source, a: std.mem.Allocator) void {
        a.free(self.inputs);
    }
};
pub const Inner = struct {
    result: NodeIndex,
    base: NodeIndex,
    visited_base: NodeIndex,
    source_sid: ?u32 = null,
    null_check: NodeIndex,
    chain_base: NodeIndex,
    rebuilt: NodeIndex,
    rebuilt_receiver: NodeIndex,
    rebuilt_key: NodeIndex,
    producer: u64 = 0,
    sid: ?u32 = null,
    write: NodeIndex = .none,
};
/// Stack-borrowed only while visiting one registered source left. The previous
/// context is restored before visiting the RHS or returning from its producer.
pub const Capture = struct { left: NodeIndex, inner: ?Inner = null, invalid: bool = false };
pub const Application = struct {
    input: Input,
    inner: Inner,
    right: NodeIndex,
    result: NodeIndex,
    producer: u64,
    sid: u32,
    write: NodeIndex,
    read: NodeIndex,
    scope: ScopeId,
};

const Topology = struct {
    live: std.AutoHashMapUnmanaged(u32, void) = .empty,
    parents: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    ambiguous: std.AutoHashMapUnmanaged(u32, void) = .empty,
    fn deinit(self: *Topology, a: std.mem.Allocator) void {
        self.live.deinit(a);
        self.parents.deinit(a);
        self.ambiguous.deinit(a);
    }
    fn init(a: std.mem.Allocator, tree: *const ast.Ast, root: NodeIndex) !Topology {
        var t: Topology = .{};
        errdefer t.deinit(a);
        const nodes = try walk.collectReachableNodeIndicesFrom(a, tree, root);
        defer a.free(nodes);
        for (nodes) |raw| {
            try t.live.put(a, raw, {});
            var children = walk.children(tree, tree.nodes.items[raw]);
            while (children.next()) |child| {
                if (child.isNone()) continue;
                const g = try t.parents.getOrPut(a, @backingInt(child));
                if (g.found_existing) {
                    if (g.value_ptr.* != raw) try t.ambiguous.put(a, @backingInt(child), {});
                } else g.value_ptr.* = raw;
            }
        }
        return t;
    }
    fn scope(self: *const Topology, tree: *const ast.Ast, owners: *const std.AutoHashMapUnmanaged(u32, u32), node: NodeIndex) ?ScopeId {
        var current = @backingInt(node);
        var hops: usize = 0;
        while (hops <= tree.nodes.items.len) : (hops += 1) {
            if (self.ambiguous.contains(current)) return null;
            const parent = self.parents.get(current) orelse return null;
            if (!@import("transformer/semantic_edit.zig").childSkipsOutputScope(tree, parent, current)) {
                if (owners.get(parent)) |s| return @fromBackingInt(s);
            }
            current = parent;
        }
        return null;
    }
    fn stableSource(self: *const Topology, tree: *const ast.Ast, node: NodeIndex) bool {
        var current = @backingInt(node);
        var hops: usize = 0;
        while (hops <= tree.nodes.items.len) : (hops += 1) {
            if (self.ambiguous.contains(current)) return false;
            const n = tree.nodes.items[current];
            switch (n.tag) {
                .program => return true,
                .formal_parameters, .formal_parameter, .arrow_function_expression, .method_definition, .class_declaration, .class_expression, .static_block, .with_statement => return false,
                .function_declaration, .function_expression, .function => {
                    const flags = tree.readExtra(n.data.extra, ast.FunctionExtra.flags);
                    if (flags & (ast.FunctionFlags.is_async | ast.FunctionFlags.is_generator) != 0) return false;
                },
                else => {},
            }
            current = self.parents.get(current) orelse return false;
        }
        return false;
    }
};

/// The caller supplies the existing exact optional-member and bound-call gates.
pub fn sourcePlan(a: std.mem.Allocator, tree: *const ast.Ast, sem: *const module.ModuleSemanticData, options: anytype, memberGate: anytype, callGate: anytype) !?Source {
    if (!options.unsupported.optional_chaining or !options.unsupported.nullish_coalescing or options.minify_syntax or sem.scopes.len == 0) return null;
    for (sem.scopes) |s| if (s.blocksMangling()) return null;
    const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
    var topology = try Topology.init(a, tree, root);
    defer topology.deinit(a);
    var inputs: std.ArrayList(Input) = .empty;
    defer inputs.deinit(a);
    var it = topology.live.keyIterator();
    while (it.next()) |raw| {
        const n = tree.nodes.items[raw.*];
        if (n.tag != .logical_expression or n.data.binary.flags != @backingInt(token.Kind.question2) or !ast.spineHasOptionalChain(tree, n.data.binary.left)) continue;
        const left = tree.getNode(n.data.binary.left);
        if ((left.tag != .static_member_expression and left.tag != .computed_member_expression) or !memberGate(tree, sem, n.data.binary.left)) return null;
        const left_nodes = try walk.collectReachableNodeIndicesFrom(a, tree, n.data.binary.left);
        defer a.free(left_nodes);
        for (left_nodes) |left_raw| switch (tree.nodes.items[left_raw].tag) {
            .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => return null,
            else => {},
        };
        const rhs = tree.getNode(n.data.binary.right);
        switch (rhs.tag) {
            .numeric_literal, .string_literal, .boolean_literal, .null_literal => {},
            .call_expression => {
                if (tree.readExtra(rhs.data.extra, 2) != 0 or tree.readExtra(rhs.data.extra, 3) != 0 or !callGate(tree, sem, tree.readExtraNode(rhs.data.extra, 0))) return null;
            },
            else => return null,
        }
        const node: NodeIndex = @fromBackingInt(raw.*);
        if (!topology.stableSource(tree, node)) return null;
        const scope = topology.scope(tree, &sem.scope_owner_map, node) orelse return null;
        if (scope.toIndex() >= sem.scopes.len) return null;
        try inputs.append(a, .{ .node = node, .left = n.data.binary.left, .right = n.data.binary.right, .scope = scope });
    }
    if (inputs.items.len == 0) return null;
    return .{ .ast = tree, .inputs = try inputs.toOwnedSlice(a), .late_names = options.defer_runtime_helper_name_resolution and !options.emit_runtime_helper_imports };
}
pub fn input(source: Source, node: NodeIndex) ?Input {
    for (source.inputs) |value| if (value.node == node) return value;
    return null;
}
pub fn recordInner(self: anytype, n: ast.Node, birth: Inner) void {
    const capture = self.optional_nullish_capture orelse return;
    const source = self.ast.getNode(capture.left);
    if (source.tag != n.tag or source.data.extra != n.data.extra or !std.meta.eql(source.span, n.span)) return;
    if (capture.inner != null) capture.invalid = true else capture.inner = birth;
}
fn ref(sem: *const module.ModuleSemanticData, tree: *const ast.Ast, topology: *const Topology, contexts: []?coordinates.Context, node: NodeIndex, sid: u32, scope: ScopeId, flags: symbol.ReferenceFlags, check_coordinates: bool, born_temp: bool) bool {
    if (!topology.live.contains(@backingInt(node)) or topology.scope(tree, &sem.scope_owner_map, node) != scope or @backingInt(node) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(node)] != sid) return false;
    const c = contexts[@backingInt(node)] orelse return false;
    var count: usize = 0;
    for (sem.references) |row| if (row.node_index == node) {
        if (@backingInt(row.symbol_id) != sid or row.scope_id != scope or !std.meta.eql(row.flags, flags) or (check_coordinates and (row.stmt_idx != c.stmt_idx or row.scope_stmt_idx != c.scope_stmt_idx)) or (!check_coordinates and born_temp and (row.stmt_idx != symbol.Reference.NO_STMT or row.scope_stmt_idx != symbol.Reference.NO_STMT))) return false;
        count += 1;
    };
    return count == 1;
}
fn temp(self: anytype, sem: *const module.ModuleSemanticData, tree: *const ast.Ast, topology: *const Topology, contexts: []?coordinates.Context, producer: u64, sid: u32, write: NodeIndex, read: NodeIndex, scope: ScopeId, check_coordinates: bool) bool {
    const source = self.optional_nullish_source orelse return false;
    const expected_kind: ?symbol.SyntheticKind = if (source.late_names) .standalone_temp_binding else null;
    if (producer == 0 or self.temp_symbols_by_producer_id.get(producer) != sid or sid >= sem.symbols.items.len or sem.symbols.items[sid].kind != .variable_var or sem.symbols.items[sid].synthetic_name.len == 0 or sem.symbols.items[sid].synthetic_kind != expected_kind or sem.symbols.items[sid].reference_count != 2 or sem.symbols.items[sid].write_count != 1) return false;
    if (!ref(sem, tree, topology, contexts, write, sid, scope, .{ .write = true }, check_coordinates, true) or !ref(sem, tree, topology, contexts, read, sid, scope, .{ .read = true }, check_coordinates, true)) return false;
    var declarations: usize = 0;
    for (sem.references) |row| if (@backingInt(row.symbol_id) == sid and row.flags.declare) {
        if (!row.node_index.isNone() or row.declaration_node_index.isNone() or row.scope_id != sem.symbols.items[sid].scope_id or !std.meta.eql(row.flags, @as(symbol.ReferenceFlags, .{ .declare = true }))) return false;
        const node = row.declaration_node_index;
        if (!topology.live.contains(@backingInt(node)) or @backingInt(node) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(node)] != sid or topology.scope(tree, &sem.scope_owner_map, node) != sem.symbols.items[sid].scope_id) return false;
        const position = contexts[@backingInt(node)] orelse return false;
        if ((check_coordinates and (row.stmt_idx != position.stmt_idx or row.scope_stmt_idx != position.scope_stmt_idx)) or
            (!check_coordinates and (row.stmt_idx != symbol.Reference.NO_STMT or row.scope_stmt_idx != symbol.Reference.NO_STMT))) return false;
        declarations += 1;
    };
    return declarations == 1;
}
fn compare(tree: *const ast.Ast, node: NodeIndex, op: token.Kind, left: NodeIndex) bool {
    const n = tree.getNode(node);
    return n.tag == .binary_expression and n.data.binary.flags == @backingInt(op) and n.data.binary.left == left and !n.data.binary.right.isNone() and @backingInt(n.data.binary.right) < tree.nodes.items.len and tree.getNode(n.data.binary.right).tag == .null_literal;
}
fn chainContainsBase(tree: *const ast.Ast, node: NodeIndex, base: NodeIndex) bool {
    var current = node;
    var hops: usize = 0;
    while (hops <= tree.nodes.items.len) : (hops += 1) {
        if (current == base) return true;
        if (current.isNone() or @backingInt(current) >= tree.nodes.items.len) return false;
        const n = tree.getNode(current);
        if (n.tag != .static_member_expression and n.tag != .computed_member_expression) return false;
        if (!tree.hasExtra(n.data.extra, 2) or tree.readExtra(n.data.extra, 2) != 0) return false;
        current = tree.readExtraNode(n.data.extra, 0);
    }
    return false;
}
/// Read-only completion. The independent late exact graph audit is also required.
fn validate(self: anytype, sem: *const module.ModuleSemanticData, root: NodeIndex, check_coordinates: bool) !bool {
    const source = self.optional_nullish_source orelse return false;
    if (source.ast != self.semantic_source_ast or source.output != self.ast or source.owner == .unassigned or source.owner != sem.owner_token or source.late_names != (self.options.defer_runtime_helper_name_resolution and !self.options.emit_runtime_helper_imports) or self.optional_nullish_applications.items.len != source.inputs.len) return false;
    if (root.isNone() or @backingInt(root) >= self.ast.nodes.items.len or self.ast.getNode(root).tag != .program) return false;
    var topology = try Topology.init(self.allocator, self.ast, root);
    defer topology.deinit(self.allocator);
    const contexts = try coordinates.collect(self.allocator, self.ast, root);
    defer self.allocator.free(contexts);
    for (source.inputs) |expected| {
        var found: ?Application = null;
        for (self.optional_nullish_applications.items) |application| if (application.input.node == expected.node) {
            if (found != null) return false;
            found = application;
        };
        const app = found orelse return false;
        for ([_]NodeIndex{ expected.node, expected.left, expected.right }) |node| {
            if (node.isNone() or @backingInt(node) >= source.ast.nodes.items.len) return false;
        }
        for ([_]NodeIndex{ app.result, app.right, app.write, app.read, app.inner.result, app.inner.base, app.inner.visited_base, app.inner.null_check, app.inner.chain_base, app.inner.rebuilt }) |node| {
            if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) return false;
        }
        if (!std.meta.eql(expected, app.input) or app.scope != expected.scope or !topology.live.contains(@backingInt(app.result)) or topology.scope(self.ast, &sem.scope_owner_map, app.result) != expected.scope) return false;
        const original = source.ast.getNode(expected.node);
        if (original.tag != .logical_expression or original.data.binary.flags != @backingInt(token.Kind.question2) or original.data.binary.left != expected.left or original.data.binary.right != expected.right) return false;
        const result = self.ast.getNode(app.result);
        if (result.tag != .conditional_expression or result.data.ternary.b != app.read or result.data.ternary.c != app.right) return false;
        if (result.data.ternary.a.isNone() or @backingInt(result.data.ternary.a) >= self.ast.nodes.items.len) return false;
        const test_node = self.ast.getNode(result.data.ternary.a);
        if (test_node.tag != .binary_expression or test_node.data.binary.left.isNone() or @backingInt(test_node.data.binary.left) >= self.ast.nodes.items.len) return false;
        const assignment = self.ast.getNode(test_node.data.binary.left);
        if (assignment.tag != .assignment_expression or assignment.data.binary.flags != @backingInt(token.Kind.eq) or assignment.data.binary.left != app.write or assignment.data.binary.right != app.inner.result or !compare(self.ast, result.data.ternary.a, .neq, test_node.data.binary.left)) return false;
        if (!temp(self, sem, self.ast, &topology, contexts, app.producer, app.sid, app.write, app.read, app.scope, check_coordinates)) return false;
        const rebuilt = self.ast.getNode(app.inner.rebuilt);
        if ((rebuilt.tag != .static_member_expression and rebuilt.tag != .computed_member_expression) or !self.ast.hasExtra(rebuilt.data.extra, 2) or self.ast.readExtraNode(rebuilt.data.extra, 0) != app.inner.rebuilt_receiver or self.ast.readExtraNode(rebuilt.data.extra, 1) != app.inner.rebuilt_key or !chainContainsBase(self.ast, app.inner.rebuilt, app.inner.chain_base)) return false;
        const inner = self.ast.getNode(app.inner.result);
        if (inner.tag != .conditional_expression or inner.data.ternary.a.isNone() or inner.data.ternary.b.isNone() or @backingInt(inner.data.ternary.a) >= self.ast.nodes.items.len or @backingInt(inner.data.ternary.b) >= self.ast.nodes.items.len or inner.data.ternary.c != app.inner.rebuilt or !compare(self.ast, inner.data.ternary.a, .eq2, app.inner.null_check)) return false;
        const zero = self.ast.getNode(inner.data.ternary.b);
        if (zero.tag != .unary_expression or self.ast.readExtra(zero.data.extra, 1) != @backingInt(token.Kind.kw_void)) return false;
        if (app.inner.producer != 0) {
            const capture = self.ast.getNode(app.inner.null_check);
            if (capture.tag != .assignment_expression or capture.data.binary.left != app.inner.write or capture.data.binary.right != app.inner.visited_base or capture.data.binary.flags != @backingInt(token.Kind.eq) or app.inner.sid == null or app.inner.sid.? == app.sid or app.inner.producer == app.producer) return false;
            if (!temp(self, sem, self.ast, &topology, contexts, app.inner.producer, app.inner.sid.?, app.inner.write, app.inner.chain_base, app.scope, check_coordinates)) return false;
        } else {
            if (app.inner.null_check != app.inner.visited_base or app.inner.sid != null or !app.inner.write.isNone() or app.inner.base.isNone()) return false;
            const sid = app.inner.source_sid orelse return false;
            if (@backingInt(app.inner.base) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(app.inner.base)] != sid) return false;
            if (!ref(sem, self.ast, &topology, contexts, app.inner.visited_base, sid, app.scope, .{ .read = true }, check_coordinates, false) or !ref(sem, self.ast, &topology, contexts, app.inner.chain_base, sid, app.scope, .{ .read = true }, check_coordinates, false)) return false;
        }
    }
    return true;
}

/// The known creators have completed but their generated references carry the
/// explicit NO_STMT birth sentinel. Validate all authority before allocating
/// an independent positions-only projection. No ID, Scope or flag is changed.
pub fn publishPositions(self: anytype, sem: *module.ModuleSemanticData, root: NodeIndex) !bool {
    if (self.optional_nullish_published_root) |published| return published == root and try complete(self, sem, root);
    if (!try validate(self, sem, root, false)) return false;
    const projected = (try @import("../bundler/statement_owner_projection.zig").project(self.allocator, self.ast, root, sem)) orelse return false;
    // All validation and allocations precede either publication.
    sem.references = projected;
    self.references = projected;
    self.optional_nullish_published_root = root;
    return true;
}
pub fn complete(self: anytype, sem: *const module.ModuleSemanticData, root: NodeIndex) !bool {
    if (self.optional_nullish_published_root != root) return false;
    return validate(self, sem, root, true);
}
