//! Exact source-function to generated state-machine callback handoff.
//! Captured before visiting the source body; no runtime registry is involved.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Scope = @import("scope.zig");
const History = @import("scope_frame_history.zig");
pub const Source = struct {
    owner: History.Owner,
    scope: Scope.ScopeId,
    parameters: Ast.NodeIndex,
    body: Ast.NodeIndex,
    extracted_loop: ?ExtractedLoop = null,
};
pub const ExtractedLoop = struct {
    loop_owner: History.Owner,
    loop_scope: Scope.ScopeId,
    loop_body: Ast.NodeIndex,
    loop_body_owner: ?History.Owner = null,
    function_owner: History.Owner,
    function_scope: Scope.ScopeId,
    parameters: Ast.NodeIndex,
    body: Ast.NodeIndex,
    birth_epoch: u32,
};
pub const HeritageRead = struct {
    owner: History.Owner,
    scope: Scope.ScopeId,
    heritage: Ast.NodeIndex,
    await_node: Ast.NodeIndex,
    read: Ast.NodeIndex,
};
pub const Capture = struct { source: Source, heritages: []const HeritageRead };
pub const Transfer = struct {
    source: Source,
    callback: History.Owner,
    callback_scope: Scope.ScopeId,
    parameters: Ast.NodeIndex,
    body: Ast.NodeIndex,
    state_parameter: Ast.NodeIndex,
    birth_epoch: u32,
    heritage: ?HeritageRead = null,
    computed_await_source: ?u32 = null,
};

/// Called by the actual per-iteration function producer before its generator
/// visit. The enclosing ordinary source owner and loop are selected by their
/// existing scope edges, never by a generated spelling or source span.
pub fn captureExtractedLoop(tree: *const Ast.Ast, source_loop: Ast.NodeIndex, function: Ast.NodeIndex, function_scope: Scope.ScopeId, loop_scope: Scope.ScopeId, initial: History.History, current: History.History) ?Source {
    if (loop_scope.isNone() or loop_scope.toIndex() >= initial.source_scopes.len) return null;
    const enclosing = Scope.enclosingExecUnit(initial.source_scopes, loop_scope) orelse return null;
    var original: ?Source = null;
    var loop: ?History.OwnerBinding = null;
    const loop_owner = (History.Owner.capture(tree, source_loop) catch return null) orelse return null;
    const while_body: ?Ast.NodeIndex = switch (loop_owner.tag) {
        .while_statement, .do_while_statement => @fromBackingInt(loop_owner.words[1]),
        .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement => null,
        else => return null,
    };
    var body_owner: ?History.Owner = null;
    for (initial.source_owners) |binding| {
        if (@backingInt(binding.scope) == enclosing) {
            switch (binding.owner.tag) {
                .function_declaration, .function_expression, .method_definition, .arrow_function_expression => {
                    if (original != null or initial.source_scopes[binding.scope.toIndex()].kind != .function or binding.edges.parameters.isNone() or binding.edges.body.isNone()) return null;
                    // This producer runs after visiting the native outer body.
                    // Its source authority is the initial owner/child snapshot;
                    // the generated loop is authenticated separately below.
                    original = .{ .owner = binding.owner, .scope = binding.scope, .parameters = binding.edges.parameters, .body = binding.edges.body };
                },
                else => {},
            }
        }
        if (while_body) |body| {
            if (binding.owner.node == body) {
                if (body_owner != null or binding.scope.isNone() or binding.scope.toIndex() >= initial.source_scopes.len or initial.source_scopes[binding.scope.toIndex()].parent != loop_scope) return null;
                body_owner = binding.owner;
            }
        } else if (binding.scope == loop_scope and std.meta.eql(binding.owner, loop_owner)) {
            if (loop != null or binding.edges.body.isNone()) return null;
            loop = binding;
        }
    }
    var source = original orelse return null;
    const loop_body = if (while_body) |body| blk: {
        if (body_owner == null) return null;
        break :blk body;
    } else (loop orelse return null).edges.body;
    const owner = (History.Owner.capture(tree, function) catch return null) orelse return null;
    const actual = edges(tree, owner) orelse return null;
    if (owner.tag != .function_expression or !std.meta.eql(owner.span, loop_owner.span)) return null;
    var epoch: ?u32 = null;
    for (current.events, 1..) |event, n| {
        if (event.kind != .birth or event.scope != function_scope) continue;
        if (epoch != null or event.after.parent != loop_scope or event.owner_after == null or !std.meta.eql(event.owner_after.?, owner) or
            event.owner_edges.parameters != actual.parameters or event.owner_edges.body != actual.body or event.actor.role != .editor or event.actor.module_index != null) return null;
        epoch = @intCast(n);
    }
    source.extracted_loop = .{ .loop_owner = loop_owner, .loop_scope = loop_scope, .loop_body = loop_body, .loop_body_owner = body_owner, .function_owner = owner, .function_scope = function_scope, .parameters = actual.parameters, .body = actual.body, .birth_epoch = epoch orelse return null };
    return source;
}

fn edges(tree: *const Ast.Ast, owner: History.Owner) ?struct { parameters: Ast.NodeIndex, body: Ast.NodeIndex } {
    const params: u32 = switch (owner.tag) {
        .function_declaration, .function_expression, .method_definition => Ast.FunctionExtra.params,
        .arrow_function_expression => Ast.ArrowExtra.params,
        else => return null,
    };
    const body: u32 = if (owner.tag == .arrow_function_expression) Ast.ArrowExtra.body else Ast.FunctionExtra.body;
    if (!tree.hasExtra(owner.words[0], @max(params, body))) return null;
    const parameters = tree.readExtraNode(owner.words[0], params);
    const body_node = tree.readExtraNode(owner.words[0], body);
    if (parameters.isNone() or @backingInt(parameters) >= tree.nodes.items.len or body_node.isNone() or @backingInt(body_node) >= tree.nodes.items.len) return null;
    if (tree.getNode(parameters).tag != .formal_parameters) return null;
    return .{ .parameters = parameters, .body = body_node };
}

pub fn capture(tree: *const Ast.Ast, node: Ast.NodeIndex, history: History.History) ?Source {
    const owner = (History.Owner.capture(tree, node) catch return null) orelse return null;
    const actual = edges(tree, owner) orelse return null;
    var result: ?Source = null;
    for (history.source_owners) |binding| {
        if (!std.meta.eql(binding.owner, owner)) continue;
        if (binding.edges.parameters != actual.parameters or binding.edges.body != actual.body) return null;
        if (result != null or binding.scope.isNone() or binding.scope.toIndex() >= history.source_scopes.len or history.source_scopes[binding.scope.toIndex()].kind != .function) return null;
        result = .{ .owner = owner, .scope = binding.scope, .parameters = actual.parameters, .body = actual.body };
    }
    return result;
}

fn awaitRead(tree: *const Ast.Ast, root: Ast.NodeIndex) ?struct { await_node: Ast.NodeIndex, read: Ast.NodeIndex } {
    var node = root;
    var fuel = tree.nodes.items.len;
    while (!node.isNone() and @backingInt(node) < tree.nodes.items.len and fuel > 0) : (fuel -= 1) {
        const current = tree.getNode(node);
        if (current.tag == .parenthesized_expression) {
            node = current.data.unary.operand;
            continue;
        }
        if (current.tag != .await_expression) return null;
        const read = current.data.unary.operand;
        if (read.isNone() or @backingInt(read) >= tree.nodes.items.len or tree.getNode(read).tag != .identifier_reference) return null;
        return .{ .await_node = node, .read = read };
    }
    return null;
}

pub fn captureHeritages(a: std.mem.Allocator, tree: *const Ast.Ast, history: History.History, source: Source, ids: []const ?u32, unresolved: ?*const std.AutoHashMapUnmanaged(u32, void)) !Capture {
    var found: std.ArrayList(HeritageRead) = .empty;
    errdefer found.deinit(a);
    const known_unresolved = unresolved orelse return .{ .source = source, .heritages = try found.toOwnedSlice(a) };
    for (history.source_owners) |binding| {
        if (binding.owner.tag != .class_declaration and binding.owner.tag != .class_expression) continue;
        var scope = binding.scope;
        var fuel = history.source_scopes.len;
        while (!scope.isNone() and scope != source.scope and fuel > 0) : (fuel -= 1) {
            if (scope.toIndex() >= history.source_scopes.len) break;
            const frame = history.source_scopes[scope.toIndex()];
            if (frame.kind == .function) break;
            scope = frame.parent;
        }
        if (scope != source.scope or !tree.hasExtra(binding.owner.words[0], Ast.ClassExtra.super)) continue;
        const heritage = binding.edges.heritage;
        if (heritage.isNone() or tree.readExtraNode(binding.owner.words[0], Ast.ClassExtra.super) != heritage) continue;
        const selected = awaitRead(tree, heritage) orelse continue;
        const raw = @backingInt(selected.read);
        if (raw >= ids.len or ids[raw] != null or !known_unresolved.contains(raw)) continue;
        try found.append(a, .{ .owner = binding.owner, .scope = binding.scope, .heritage = heritage, .await_node = selected.await_node, .read = selected.read });
    }
    return .{ .source = source, .heritages = try found.toOwnedSlice(a) };
}

pub fn completed(tree: *const Ast.Ast, source: Source, callback: Ast.NodeIndex, callback_scope: Scope.ScopeId, state_parameter: Ast.NodeIndex, history: History.History) ?Transfer {
    const owner = (History.Owner.capture(tree, callback) catch return null) orelse return null;
    const actual = edges(tree, owner) orelse return null;
    var epoch: ?u32 = null;
    for (history.events, 1..) |event, n| {
        if (event.kind != .birth or event.scope != callback_scope or event.owner_after == null or !std.meta.eql(event.owner_after.?, owner)) continue;
        if (epoch != null) return null;
        epoch = @intCast(n);
    }
    return .{ .source = source, .callback = owner, .callback_scope = callback_scope, .parameters = actual.parameters, .body = actual.body, .state_parameter = state_parameter, .birth_epoch = epoch orelse return null };
}

fn below(index: *const History.Index, start: Scope.ScopeId, ancestor: Scope.ScopeId, epoch: u32, count: usize) bool {
    var scope = start;
    var fuel = count + 1;
    while (!scope.isNone() and fuel > 0) : (fuel -= 1) {
        if (scope == ancestor) return true;
        scope = (index.frameAt(scope, epoch) orelse return false).parent;
    }
    return false;
}

fn validExtractedLoop(tree: *const Ast.Ast, index: *const History.Index, parser_count: u32, from: Scope.ScopeId, epoch: u32, count: usize, source: Source, loop: ExtractedLoop) bool {
    if (loop.loop_owner.node.isNone() or @backingInt(loop.loop_owner.node) >= parser_count or
        loop.loop_body.isNone() or @backingInt(loop.loop_body) >= parser_count or loop.function_owner.tag != .function_expression or
        loop.function_owner.node.isNone() or @backingInt(loop.function_owner.node) < parser_count or
        loop.birth_epoch == 0 or loop.birth_epoch > epoch or loop.birth_epoch > index.history.events.len or
        !below(index, loop.loop_scope, source.scope, 0, count) or !below(index, from, loop.function_scope, epoch, count)) return false;
    var origins: usize = 0;
    for (index.history.source_owners) |binding| {
        if (loop.loop_body_owner) |body_owner| {
            if (loop.loop_owner.tag != .while_statement and loop.loop_owner.tag != .do_while_statement) return false;
            if (loop.loop_owner.words[1] != @backingInt(loop.loop_body) or body_owner.node != loop.loop_body) return false;
            if (std.meta.eql(binding.owner, body_owner) and (index.frameAt(binding.scope, 0) orelse return false).parent == loop.loop_scope) origins += 1;
        } else if ((loop.loop_owner.tag == .for_statement or loop.loop_owner.tag == .for_in_statement or loop.loop_owner.tag == .for_of_statement or loop.loop_owner.tag == .for_await_of_statement) and binding.scope == loop.loop_scope and std.meta.eql(binding.owner, loop.loop_owner) and binding.edges.body == loop.loop_body) origins += 1;
    }
    if (origins != 1) return false;
    const birth = index.history.events[loop.birth_epoch - 1];
    if (birth.kind != .birth or birth.scope != loop.function_scope or birth.after.parent != loop.loop_scope or
        birth.actor.role != .editor or birth.actor.module_index != null or birth.owner_after == null or !std.meta.eql(birth.owner_after.?, loop.function_owner) or
        birth.owner_edges.parameters != loop.parameters or birth.owner_edges.body != loop.body or !std.meta.eql(loop.function_owner.span, loop.loop_owner.span)) return false;
    const actual = edges(tree, loop.function_owner) orelse return false;
    return actual.parameters == loop.parameters and actual.body == loop.body;
}

pub fn validates(tree: *const Ast.Ast, index: *const History.Index, parser_count: u32, source_node: Ast.NodeIndex, flags: @import("symbol.zig").ReferenceFlags, with_environment: bool, source_scope: Scope.ScopeId, execution_scope: Scope.ScopeId, from: Scope.ScopeId, to: Scope.ScopeId, epoch: u32, count: usize, transfer: Transfer) bool {
    if (transfer.source.owner.node.isNone() or @backingInt(transfer.source.owner.node) >= parser_count or
        transfer.source.parameters.isNone() or @backingInt(transfer.source.parameters) >= parser_count or
        transfer.source.body.isNone() or @backingInt(transfer.source.body) >= parser_count or
        transfer.callback.node.isNone() or @backingInt(transfer.callback.node) < parser_count) return false;
    if (transfer.birth_epoch == 0 or transfer.birth_epoch > epoch or transfer.birth_epoch > index.history.events.len or
        !below(index, source_scope, transfer.source.scope, 0, count) or !below(index, execution_scope, transfer.source.scope, 0, count) or
        !below(index, to, transfer.callback_scope, epoch, count) or
        !below(index, transfer.callback_scope, transfer.source.scope, transfer.birth_epoch, count)) return false;
    var sources: usize = 0;
    for (index.history.source_owners) |binding| if (binding.scope == transfer.source.scope and std.meta.eql(binding.owner, transfer.source.owner) and binding.edges.parameters == transfer.source.parameters and binding.edges.body == transfer.source.body) {
        sources += 1;
    };
    if (sources != 1) return false;
    if (transfer.source.extracted_loop) |loop| {
        if (!validExtractedLoop(tree, index, parser_count, from, epoch, count, transfer.source, loop) or
            !below(index, transfer.callback_scope, loop.function_scope, transfer.birth_epoch, count)) return false;
    }
    const source_edges = edges(tree, transfer.source.owner) orelse return false;
    if (source_edges.parameters != transfer.source.parameters or source_edges.body != transfer.source.body) return false;
    const birth = index.history.events[transfer.birth_epoch - 1];
    if (birth.kind != .birth or birth.scope != transfer.callback_scope or birth.actor.role != .editor or birth.actor.module_index != null or birth.owner_after == null or
        !std.meta.eql(birth.owner_after.?, transfer.callback) or transfer.callback.tag != .function_expression or
        !std.meta.eql(transfer.callback.span, if (transfer.source.extracted_loop) |loop| loop.loop_owner.span else transfer.source.owner.span)) return false;
    const current = (History.Owner.capture(tree, transfer.callback.node) catch return false) orelse return false;
    if (!std.meta.eql(current, transfer.callback)) return false;
    const target = tree.getNode(transfer.callback.node);
    const callback_edges = edges(tree, transfer.callback) orelse return false;
    if (callback_edges.parameters != transfer.parameters or callback_edges.body != transfer.body or
        !tree.hasExtra(target.data.extra, Ast.FunctionExtra.flags) or tree.readExtra(target.data.extra, Ast.FunctionExtra.flags) != 0 or
        tree.readExtraNode(target.data.extra, Ast.FunctionExtra.name) != .none or tree.getNode(transfer.body).tag != .block_statement or !std.meta.eql(tree.getNode(transfer.body).span, transfer.callback.span)) return false;
    const params_node = tree.getNode(transfer.parameters);
    const list = params_node.data.list;
    if (list.len != 1 or list.start >= tree.extra_data.items.len or tree.extra_data.items[list.start] != @backingInt(transfer.state_parameter) or
        transfer.state_parameter.isNone() or @backingInt(transfer.state_parameter) >= tree.nodes.items.len or tree.getNode(transfer.state_parameter).tag != .binding_identifier) return false;
    const before = index.frameAt(from, epoch) orelse return false;
    const after = index.frameAt(to, epoch) orelse return false;
    if (before.subtree_has_direct_eval != after.subtree_has_direct_eval or before.subtree_has_with != after.subtree_has_with) return false;
    if (before.is_strict == after.is_strict) return true;
    if (transfer.computed_await_source) |key_index| {
        if (key_index >= index.history.source_computed_awaits.len or transfer.heritage != null) return false;
        const key = index.history.source_computed_awaits[key_index];
        if (!before.is_strict or after.is_strict or with_environment or !flags.read or flags.write or flags.declare or flags.type_context or flags.value_as_type or
            key.leaf.node != source_node or key.scope != execution_scope or source_scope != execution_scope or
            key.key.tag != .computed_property_key or key.await_node.tag != .await_expression or key.leaf.tag != .identifier_reference or
            key.key.words[0] != @backingInt(key.await_node.node) or before.subtree_has_direct_eval or before.subtree_has_with) return false;
        var classes: usize = 0;
        for (index.history.source_owners) |binding| if (binding.scope == key.scope and std.meta.eql(binding.owner, key.class_owner)) {
            classes += 1;
        };
        return classes == 1;
    }
    // An unresolved identifier value read is strict-neutral. This exception is
    // confined to the actual direct `extends (await identifier)` source edge;
    // calls/eval, assignments, class-self identities and arbitrary subtrees do
    // not acquire this authority.
    const heritage = transfer.heritage orelse return false;
    if (!before.is_strict or after.is_strict or with_environment or !flags.read or flags.write or flags.declare or flags.type_context or flags.value_as_type or
        heritage.read != source_node or heritage.scope != execution_scope or source_scope != execution_scope) return false;
    var classes: usize = 0;
    for (index.history.source_owners) |binding| if (binding.scope == heritage.scope and std.meta.eql(binding.owner, heritage.owner) and binding.edges.heritage == heritage.heritage) {
        classes += 1;
    };
    if (classes != 1 or (heritage.owner.tag != .class_declaration and heritage.owner.tag != .class_expression) or
        !tree.hasExtra(heritage.owner.words[0], Ast.ClassExtra.super) or tree.readExtraNode(heritage.owner.words[0], Ast.ClassExtra.super) != heritage.heritage) return false;
    const actual = awaitRead(tree, heritage.heritage) orelse return false;
    return actual.await_node == heritage.await_node and actual.read == heritage.read;
}
