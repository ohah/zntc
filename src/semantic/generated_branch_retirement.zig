//! Exact syntax-minifier discarded-edge authority for generated iterator scopes.
//! A live owner, foreign catch birth, or escaping identity never retires here.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Drop = @import("source_drop_registry.zig");
const Scope = @import("scope.zig");
const Symbols = @import("symbol.zig");
const History = @import("scope_frame_history.zig");
const Retirement = @import("source_owned_retirement.zig");

pub const Branch = struct {
    control: Drop.Node,
    condition: Drop.Node,
    dropped: Drop.Node,
    kept: ?Drop.Node,
    control_after: Drop.Node,
    source_epoch: u32,
    root_scope: Scope.ScopeId,
    truthy: bool,
};

pub const Witness = struct {
    branch: Branch,
    catch_owner: Drop.Node,
    catch_scope: Scope.ScopeId,
};

pub fn node(snapshot: Drop.Node) Ast.Node {
    var result: Ast.Node = .{ .tag = snapshot.tag, .span = snapshot.span, .data = std.mem.zeroes(Ast.Node.Data) };
    const width = snapshot.tag.dataWidth();
    @memcpy(std.mem.asBytes(&result.data)[0..width], snapshot.data[0..width]);
    return result;
}

/// The journal calls this before changing the controlling edge. No identifier
/// spelling or unvalidated constant alias grants a literal proof.
pub fn literalTruthiness(a: std.mem.Allocator, tree: *const Ast.Ast, condition: Drop.Node) std.mem.Allocator.Error!?bool {
    if (!condition.matches(tree)) return null;
    const value = node(condition);
    return switch (value.tag) {
        .null_literal => false,
        .boolean_literal => boolean: {
            const text = tree.getText(value.span);
            if (std.mem.eql(u8, text, "true")) break :boolean true;
            if (std.mem.eql(u8, text, "false")) break :boolean false;
            break :boolean null;
        },
        .numeric_literal => number: {
            const number = @import("../transformer/minify/numeric.zig").parseLiteral(tree, value) orelse break :number null;
            break :number number != 0 and !std.math.isNan(number);
        },
        .string_literal => string: {
            const text = @import("../string_escape.zig").decodeJsStringLiteral(a, tree.getText(value.span)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :string null,
            };
            defer a.free(text);
            break :string text.len != 0;
        },
        else => null,
    };
}

/// Generated owner histories have one actual birth followed by explicit owner
/// edits. Query only this scope's indexed events, never all module owners.
pub fn ownerAt(index: *const History.Index, scope: Scope.ScopeId, owner: Ast.NodeIndex, epoch: u32) bool {
    if (!index.valid or scope.isNone() or scope.toIndex() + 1 >= index.offsets.len or epoch > index.history.events.len) return false;
    const events = index.event_indices[index.offsets[scope.toIndex()]..index.offsets[scope.toIndex() + 1]];
    var present = false;
    if (scope.toIndex() < index.history.source_scopes.len) {
        const owners = index.history.source_owners;
        var low: usize = 0;
        var high = owners.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (@backingInt(owners[middle].owner.node) < @backingInt(owner)) low = middle + 1 else high = middle;
        }
        present = low < owners.len and owners[low].owner.node == owner and owners[low].scope == scope;
    }
    for (events) |raw| {
        if (raw >= epoch) break;
        const event = index.history.events[raw];
        if (event.kind != .birth and event.kind != .owner) continue;
        if (event.owner_before) |before| {
            if (before.node == owner) present = false;
        }
        if (event.owner_after) |after| {
            if (after.node == owner) present = true;
        }
    }
    return present;
}

fn belowAt(index: *const History.Index, start: Scope.ScopeId, ancestor: Scope.ScopeId, epoch: u32) bool {
    var cursor = start;
    var fuel = index.offsets.len;
    while (!cursor.isNone() and fuel != 0) : (fuel -= 1) {
        if (cursor == ancestor) return true;
        const frame = index.frameAt(cursor, epoch) orelse return false;
        cursor = frame.parent;
    }
    return false;
}

pub const Prepared = struct {
    branch: Branch,
    members: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        self.members.deinit(a);
    }
};

pub fn prepare(a: std.mem.Allocator, tree: *const Ast.Ast, branch: Branch, live: *const std.DynamicBitSet, index: *const History.Index) std.mem.Allocator.Error!?Prepared {
    if (!index.valid or branch.control.tag != .if_statement or branch.dropped.tag != .block_statement or
        branch.control.index.isNone() or @backingInt(branch.control.index) >= tree.nodes.items.len or
        branch.control_after.index != branch.control.index or !branch.control_after.matches(tree) or
        !branch.dropped.matches(tree) or branch.dropped.index.isNone() or
        @backingInt(branch.dropped.index) >= live.capacity() or live.isSet(@backingInt(branch.dropped.index))) return null;
    const control = node(branch.control);
    if (control.data.ternary.a != branch.condition.index or
        (if (branch.truthy) control.data.ternary.c else control.data.ternary.b) != branch.dropped.index or
        (if (branch.truthy) control.data.ternary.b else control.data.ternary.c) != (if (branch.kept) |kept| kept.index else Ast.NodeIndex.none)) return null;
    const truthy = (try literalTruthiness(a, tree, branch.condition)) orelse return null;
    if (truthy != branch.truthy or !ownerAt(index, branch.root_scope, branch.dropped.index, branch.source_epoch)) return null;
    const frame = index.frameAt(branch.root_scope, branch.source_epoch) orelse return null;
    if (frame.kind != .block) return null;
    const dropped = node(branch.dropped);
    if (dropped.data.list.start > tree.extra_data.items.len or dropped.data.list.len > tree.extra_data.items.len - dropped.data.list.start) return null;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, tree, branch.dropped.index);
    defer a.free(nodes);
    var result: Prepared = .{ .branch = branch };
    errdefer result.deinit(a);
    try result.members.ensureTotalCapacity(a, @intCast(nodes.len));
    for (nodes) |raw| {
        if (raw >= live.capacity() or live.isSet(raw)) {
            result.deinit(a);
            return null;
        }
        result.members.putAssumeCapacity(raw, {});
    }
    return result;
}

pub fn validate(w: Retirement.Witness, prepared: *const Prepared, tree: *const Ast.Ast, rows: []const Symbols.Symbol, ids: []const ?u32, index: *const History.Index) bool {
    const proof = w.generated_branch orelse return false;
    if (!std.meta.eql(proof.branch, prepared.branch) or w.reason != .generated_branch or
        w.erased_import != null or w.static_capture_alias != null or w.function_name_elision != null or
        w.enum_environment != null or w.dropped_statement != null or w.inlined_binding != null or
        @backingInt(w.symbol_id) >= rows.len or w.before.kind != .catch_binding or
        w.before.synthetic_name.len == 0 or proof.catch_scope.toIndex() < index.history.source_scopes.len or w.before.scope_id != proof.catch_scope or
        w.before.origin_scope != proof.catch_scope or w.source_scope != proof.catch_scope or
        w.source_owner != proof.branch.dropped.index or !equalBlockOwner(w.source_owner_node, node(proof.branch.dropped)) or
        w.closure_scope != proof.catch_scope or !prepared.members.contains(@backingInt(proof.catch_owner.index)) or
        proof.catch_owner.tag != .catch_clause or !proof.catch_owner.matches(tree) or
        !ownerAt(index, proof.catch_scope, proof.catch_owner.index, proof.branch.source_epoch)) return false;
    const root = index.frameAt(proof.branch.root_scope, proof.branch.source_epoch) orelse return false;
    const caught = index.frameAt(proof.catch_scope, proof.branch.source_epoch) orelse return false;
    if (root.kind != .block or caught.kind != .catch_clause or caught.parent != w.closure_parent or caught.parent != w.source_parent or
        !belowAt(index, proof.catch_scope, proof.branch.root_scope, proof.branch.source_epoch) or
        !belowAt(index, proof.catch_scope, proof.branch.root_scope, @intCast(index.history.events.len))) return false;
    const binding = w.declaration_node orelse return false;
    const catch_node = node(proof.catch_owner);
    if (catch_node.data.binary.left != w.source_name or w.source_name_symbol != w.symbol_id or
        w.source_name.isNone() or @backingInt(w.source_name) >= ids.len or ids[@backingInt(w.source_name)] != null or
        binding.tag != .binding_identifier or !prepared.members.contains(@backingInt(w.source_name)) or
        !@import("import_erasure.zig").equalNode(tree.getNode(w.source_name), binding) or
        !std.meta.eql(w.before.name, binding.data.string_ref) or
        w.declaration.symbol_id != w.symbol_id or w.declaration.scope_id != proof.catch_scope or
        w.declaration.declaration_node_index != w.source_name or !w.declaration.node_index.isNone() or
        !std.meta.eql(w.declaration.flags, @as(Symbols.ReferenceFlags, .{ .declare = true }))) return false;
    var expected = w.before;
    expected.reference_count = 0;
    expected.write_count = 0;
    return Retirement.equalSymbol(expected, rows[@backingInt(w.symbol_id)]);
}

/// This witness owns a block payload. Import-erasure equality deliberately
/// rejects block nodes and must never be used as a generic AST comparator.
fn equalBlockOwner(left: Ast.Node, right: Ast.Node) bool {
    return left.tag == .block_statement and right.tag == .block_statement and
        std.meta.eql(left.span, right.span) and std.meta.eql(left.data.list, right.data.list);
}

test "lazy iterator generated branch block owner compares active block payload only" {
    const base: Ast.Node = .{ .tag = .block_statement, .span = .{ .start = 3, .end = 9 }, .data = .{ .list = .{ .start = 2, .len = 4 } } };
    try std.testing.expect(equalBlockOwner(base, base));
    var changed = base;
    changed.data.list.len += 1;
    try std.testing.expect(!equalBlockOwner(base, changed));
    changed = base;
    changed.span.start += 1;
    try std.testing.expect(!equalBlockOwner(base, changed));
    changed = base;
    changed.tag = .array_expression;
    try std.testing.expect(!equalBlockOwner(base, changed));
}
