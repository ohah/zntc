//! Exact, persistent lineage for a registered Worklet class lowered to an IIFE.
//! This proves a virtual class environment; it never retires or rewrites a SID.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const symbols = @import("symbol.zig");
const scopes = @import("scope.zig");
const NodeIndex = ast.NodeIndex;
const ScopeId = scopes.ScopeId;
const SymbolId = symbols.SymbolId;

pub const Class = struct {
    node: NodeIndex,
    body: NodeIndex,
    name: NodeIndex,
    scope: ScopeId,
    self: SymbolId,
};
pub const Function = struct {
    node: NodeIndex,
    name: NodeIndex,
    params: NodeIndex,
    body: NodeIndex,
    scope: ScopeId,
    parent: ScopeId,
    declaration: NodeIndex,
    symbol: SymbolId,
};
/// Captured only by the registered Worklet clone creator, before lowering.
/// It is independent of the later lowerer's selection/witness record.
pub const Creator = struct {
    source: Class,
    target: Class,
    factory: NodeIndex,
    factory_binding: NodeIndex,
    factory_symbol: SymbolId,
    factory_scope: ScopeId,
    wrapper_scope: ScopeId,
    epoch: u32,
};
pub const Witness = struct {
    creator_index: u32,
    source: Class,
    target: Class,
    factory: Function,
    wrapper_scope: ScopeId,
    constructor: Function,
    iife: Function,
    creator_epoch: u32,
    lowered_epoch: u32,
};
pub const Graph = struct {
    ast_owner: *const ast.Ast,
    symbols: []const symbols.Symbol,
    scopes: []const scopes.Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    ids: []const ?u32,
    references: []const symbols.Reference,
    class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    root: NodeIndex,
    history_identity: *const anyopaque,
};
pub const Bridge = struct {
    target_scope: ScopeId,
    actual_iife_scope: ScopeId,
    constructor_scope: ScopeId,
};
pub const Proof = struct {
    entries: []const Bridge,

    pub fn deinit(self: *Proof, a: std.mem.Allocator) void {
        a.free(self.entries);
        self.* = .{ .entries = &.{} };
    }
    pub fn bridge(self: *const Proof, scope: ScopeId) ?Bridge {
        for (self.entries) |entry| if (entry.target_scope == scope) return entry;
        return null;
    }
};

fn nodeValid(tree: *const ast.Ast, node: NodeIndex) bool {
    return !node.isNone() and @backingInt(node) < tree.nodes.items.len;
}
fn scopeValid(graph: Graph, scope: ScopeId) bool {
    return !scope.isNone() and scope.toIndex() < graph.scopes.len and scope.toIndex() < graph.scope_maps.len;
}
fn attached(graph: Graph, node: NodeIndex, sid: SymbolId) bool {
    return !node.isNone() and !sid.isNone() and @backingInt(node) < graph.ids.len and
        @backingInt(sid) < graph.symbols.len and graph.ids[@backingInt(node)] == @as(?u32, @backingInt(sid));
}
fn pureDeclaration(graph: Graph, node: NodeIndex, sid: SymbolId, scope: ScopeId) bool {
    if (!attached(graph, node, sid)) return false;
    var found: usize = 0;
    for (graph.references) |reference| {
        if (reference.symbol_id != sid or !reference.flags.declare) continue;
        if (reference.declaration_node_index != node or reference.scope_id != scope or
            reference.flags.read or reference.flags.write or reference.flags.value_as_type) return false;
        found += 1;
    }
    return found == 1;
}
fn classShape(tree: *const ast.Ast, graph: Graph, role: Class) bool {
    if (!nodeValid(tree, role.node) or !nodeValid(tree, role.body) or !nodeValid(tree, role.name) or
        !scopeValid(graph, role.scope) or role.self.isNone() or @backingInt(role.self) >= graph.symbols.len) return false;
    const node = tree.getNode(role.node);
    if ((node.tag != .class_expression and node.tag != .class_declaration) or
        !tree.hasExtra(node.data.extra, ast.ClassExtra.deco_len) or
        tree.readExtraNode(node.data.extra, ast.ClassExtra.name) != role.name or
        tree.readExtraNode(node.data.extra, ast.ClassExtra.body) != role.body or
        tree.getNode(role.name).tag != .binding_identifier or tree.getNode(role.body).tag != .class_body or
        graph.class_self_symbols.get(@backingInt(role.node)) != @as(?u32, @backingInt(role.self))) return false;
    // Both Analyzer.declareClassInnerName and the registered clone creator
    // publish this immutable class-self role. Storage relocation preserves it.
    const self_symbol = graph.symbols[@backingInt(role.self)];
    return graph.scopes[role.scope.toIndex()].kind == .class_body and graph.scopes[role.scope.toIndex()].is_strict and
        self_symbol.origin_scope == role.scope and self_symbol.kind == .class_decl and
        self_symbol.decl_flags.is_class and self_symbol.decl_flags.is_const and self_symbol.decl_flags.preserve_class_name;
}
fn functionShape(tree: *const ast.Ast, role: Function) bool {
    if (!nodeValid(tree, role.node) or !nodeValid(tree, role.params) or !nodeValid(tree, role.body)) return false;
    const node = tree.getNode(role.node);
    if ((node.tag != .function_declaration and node.tag != .function_expression) or
        !tree.hasExtra(node.data.extra, ast.FunctionExtra.return_type)) return false;
    return tree.readExtraNode(node.data.extra, ast.FunctionExtra.name) == role.name and
        tree.readExtraNode(node.data.extra, ast.FunctionExtra.params) == role.params and
        tree.readExtraNode(node.data.extra, ast.FunctionExtra.body) == role.body and
        tree.getNode(role.body).tag == .block_statement;
}

// A history replay already validated by the caller is the only owner-copy
// authority. Witness nodes cannot select a same-spelled or same-shaped owner.
fn ownerAt(index: anytype, scope: ScopeId, epoch: u32) ?NodeIndex {
    if (!index.valid or epoch > index.history.events.len) return null;
    var owner: ?NodeIndex = null;
    for (index.history.source_owners) |binding| if (binding.scope == scope) {
        if (owner != null) return null;
        owner = binding.owner.node;
    };
    for (index.history.events[0..epoch]) |event| {
        if (event.scope != scope) continue;
        switch (event.kind) {
            .birth => {
                if (owner != null) return null;
                owner = if (event.owner_after) |value| value.node else null;
            },
            .frame => {},
            .owner => {
                const before = if (event.owner_before) |value| value.node else null;
                if (before != owner) return null;
                owner = if (event.owner_after) |value| value.node else null;
            },
        }
    }
    return owner;
}
const OwnerEdges = struct { node: NodeIndex, parameters: NodeIndex, body: NodeIndex };
fn ownerEdgesAt(index: anytype, scope: ScopeId, epoch: u32) ?OwnerEdges {
    if (!index.valid or epoch > index.history.events.len) return null;
    var result: ?OwnerEdges = null;
    for (index.history.source_owners) |binding| if (binding.scope == scope) {
        if (result != null) return null;
        result = .{ .node = binding.owner.node, .parameters = binding.edges.parameters, .body = binding.edges.body };
    };
    for (index.history.events[0..epoch]) |event| {
        if (event.scope != scope or event.kind == .frame) continue;
        result = if (event.owner_after) |owner| .{ .node = owner.node, .parameters = event.owner_edges.parameters, .body = event.owner_edges.body } else null;
    }
    return result;
}
fn publishedOnOwnerChain(index: anytype, scope: ScopeId, epoch: u32, node: NodeIndex) bool {
    if (ownerAt(index, scope, epoch) == node) return true;
    // Deferred remaps are published by finishSemanticEdit after the lowerer
    // records the actual constructed node. Only an explicit later owner event
    // in this same validated history can authorize that pending publication.
    for (index.history.events[epoch..]) |event| {
        if (event.scope != scope or event.kind != .owner) continue;
        if (event.owner_after) |after| if (after.node == node) return true;
    }
    return false;
}
fn contains(a: std.mem.Allocator, tree: *const ast.Ast, root: NodeIndex, wanted: NodeIndex) !bool {
    if (!nodeValid(tree, root) or !nodeValid(tree, wanted)) return false;
    const nodes = try walk.collectReachableNodeIndicesFrom(a, tree, root);
    defer a.free(nodes);
    for (nodes) |raw| if (raw == @backingInt(wanted)) return true;
    return false;
}

fn finalFunction(tree: *const ast.Ast, index: anytype, graph: Graph, role: Function, epoch: u32, storage: ScopeId) ?NodeIndex {
    if (!scopeValid(graph, role.scope) or !scopeValid(graph, role.parent) or !functionShape(tree, role)) return null;
    const before = index.frameAt(role.scope, epoch) orelse return null;
    if (before.kind != .function or before.parent != role.parent or !publishedOnOwnerChain(index, role.scope, epoch, role.node)) return null;
    if (graph.scopes[role.scope.toIndex()].kind != .function or graph.scopes[role.scope.toIndex()].parent != role.parent) return null;
    const current = ownerAt(index, role.scope, @intCast(index.history.events.len)) orelse return null;
    if (!nodeValid(tree, current) or graph.owners.get(@backingInt(current)) != @as(?u32, @backingInt(role.scope))) return null;
    const node = tree.getNode(current);
    if ((node.tag != .function_declaration and node.tag != .function_expression) or
        !tree.hasExtra(node.data.extra, ast.FunctionExtra.return_type)) return null;
    const name = tree.readExtraNode(node.data.extra, ast.FunctionExtra.name);
    const params = tree.readExtraNode(node.data.extra, ast.FunctionExtra.params);
    const body = tree.readExtraNode(node.data.extra, ast.FunctionExtra.body);
    if (!nodeValid(tree, params) or !nodeValid(tree, body) or tree.getNode(body).tag != .block_statement) return null;
    if (current == role.node) {
        if (params != role.params or body != role.body) return null;
    } else {
        const edges = ownerEdgesAt(index, role.scope, @intCast(index.history.events.len)) orelse return null;
        if (edges.node != current or edges.parameters != params or edges.body != body) return null;
    }
    if (role.symbol.isNone()) {
        if (!role.name.isNone() or !role.declaration.isNone() or !name.isNone()) return null;
    } else {
        if (role.name != role.declaration or !nodeValid(tree, name) or tree.getNode(name).tag != .binding_identifier or
            !attached(graph, name, role.symbol) or !pureDeclaration(graph, name, role.symbol, storage) or
            graph.symbols[@backingInt(role.symbol)].scope_id != storage) return null;
        const raw_name = tree.identifierNameText(tree.getNode(name));
        const mapped = graph.scope_maps[storage.toIndex()].get(raw_name) orelse return null;
        if (mapped != @as(usize, @backingInt(role.symbol))) return null;
    }
    return current;
}

/// The supplied entries must be the actual History registry of this current
/// graph. SourceCurrent/History validation binds that graph to its installed
/// domain; this module additionally validates every registered physical role.
pub fn prepare(a: std.mem.Allocator, tree: *const ast.Ast, index: anytype, entries: []const Witness, graph: Graph) !?Proof {
    if (tree != graph.ast_owner or !index.valid or graph.history_identity != @as(*const anyopaque, @ptrCast(index.history)) or
        entries.ptr != index.history.lowered_worklet_classes.ptr or entries.len != index.history.lowered_worklet_classes.len or
        graph.scopes.len != graph.scope_maps.len or !nodeValid(tree, graph.root)) return null;
    var result: std.ArrayList(Bridge) = .empty;
    defer result.deinit(a);
    for (entries) |entry| {
        if (entry.creator_index >= index.history.worklet_class_creators.len) return null;
        const creator = index.history.worklet_class_creators[entry.creator_index];
        if (!std.meta.eql(entry.source, creator.source) or !std.meta.eql(entry.target, creator.target) or
            entry.factory.node != creator.factory or entry.factory.name != creator.factory_binding or
            entry.factory.declaration != creator.factory_binding or entry.factory.symbol != creator.factory_symbol or
            entry.factory.scope != creator.factory_scope or entry.factory.parent != creator.wrapper_scope or
            entry.wrapper_scope != creator.wrapper_scope or entry.creator_epoch != creator.epoch) return null;
        if (entry.creator_epoch > entry.lowered_epoch or entry.lowered_epoch > index.history.events.len or
            !classShape(tree, graph, entry.source) or !classShape(tree, graph, entry.target) or
            entry.source.node == entry.target.node or entry.source.body == entry.target.body or
            entry.source.name == entry.target.name or entry.source.scope == entry.target.scope or entry.source.self == entry.target.self or
            entry.factory.parent != entry.wrapper_scope or entry.iife.parent != entry.factory.scope or
            entry.constructor.symbol != entry.target.self or
            entry.iife.symbol != .none or !scopeValid(graph, entry.wrapper_scope)) return null;
        const source_frame = index.frameAt(entry.source.scope, entry.creator_epoch) orelse return null;
        const target_frame = index.frameAt(entry.target.scope, entry.creator_epoch) orelse return null;
        const wrapper_frame = index.frameAt(entry.wrapper_scope, entry.creator_epoch) orelse return null;
        if (source_frame.kind != .class_body or target_frame.kind != .class_body or wrapper_frame.kind != .function or
            target_frame.parent != entry.factory.scope or source_frame.parent != wrapper_frame.parent or
            ownerAt(index, entry.source.scope, entry.creator_epoch) != entry.source.node or
            ownerAt(index, entry.target.scope, entry.creator_epoch) != entry.target.node) return null;
        const lowered = index.frameAt(entry.target.scope, entry.lowered_epoch) orelse return null;
        if (lowered.kind != .class_body or lowered.parent != entry.iife.scope or
            graph.scopes[entry.target.scope.toIndex()].parent != entry.iife.scope or
            graph.symbols[@backingInt(entry.target.self)].scope_id != entry.iife.scope) return null;
        if (entry.factory.symbol.isNone() or @backingInt(entry.factory.symbol) >= graph.symbols.len or
            graph.symbols[@backingInt(entry.factory.symbol)].kind != .function_decl or
            !graph.symbols[@backingInt(entry.factory.symbol)].decl_flags.is_function) return null;
        const factory = finalFunction(tree, index, graph, entry.factory, entry.lowered_epoch, entry.wrapper_scope) orelse return null;
        const constructor = finalFunction(tree, index, graph, entry.constructor, entry.lowered_epoch, entry.iife.scope) orelse return null;
        const iife = finalFunction(tree, index, graph, entry.iife, entry.lowered_epoch, entry.factory.scope) orelse return null;
        if (entry.constructor.parent != entry.target.scope) {
            const parameter_scope = entry.constructor.parent;
            if (!scopeValid(graph, parameter_scope) or graph.scopes[parameter_scope.toIndex()].kind != .function or
                graph.scopes[parameter_scope.toIndex()].parent != entry.target.scope) return null;
            const parameter_frame = index.frameAt(parameter_scope, entry.lowered_epoch) orelse return null;
            if (parameter_frame.kind != .function or parameter_frame.parent != entry.target.scope or
                ownerAt(index, parameter_scope, entry.lowered_epoch) != entry.constructor.params) return null;
            const actual_params = tree.readExtraNode(tree.getNode(constructor).data.extra, ast.FunctionExtra.params);
            if (ownerAt(index, parameter_scope, @intCast(index.history.events.len)) != actual_params or
                graph.owners.get(@backingInt(actual_params)) != @as(?u32, @backingInt(parameter_scope))) return null;
        }
        if (factory == constructor or factory == iife or iife == constructor or
            !try contains(a, tree, graph.root, factory) or !try contains(a, tree, graph.root, iife) or !try contains(a, tree, graph.root, constructor) or
            try contains(a, tree, graph.root, entry.target.node) or
            !try contains(a, tree, tree.readExtraNode(tree.getNode(factory).data.extra, ast.FunctionExtra.body), iife) or
            !try contains(a, tree, tree.readExtraNode(tree.getNode(iife).data.extra, ast.FunctionExtra.body), constructor)) return null;
        for (result.items) |previous| if (previous.target_scope == entry.target.scope or previous.actual_iife_scope == entry.iife.scope or previous.constructor_scope == entry.constructor.scope) return null;
        try result.append(a, .{ .target_scope = entry.target.scope, .actual_iife_scope = entry.iife.scope, .constructor_scope = entry.constructor.scope });
    }
    return .{ .entries = try result.toOwnedSlice(a) };
}
// Append only after the producer's first positive proof is measured.
test "lowered Worklet class exact bridge rejects foreign creator role and replay poisons" {
    const a = std.testing.allocator;
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const ModuleGraph = @import("../bundler/graph.zig").ModuleGraph;
    const history_mod = @import("scope_frame_history.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "export class A{__workletClass=true;value(){return 3}}export class B{__workletClass=true;value(){return 7}}");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var cache = Bundler.initResolveCacheFromOptions(a, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs });
    defer cache.deinit();
    const modules = try a.create(ModuleGraph);
    defer a.destroy(modules);
    modules.* = ModuleGraph.init(a, &cache);
    defer modules.deinit();
    modules.worklet_transform = true;
    modules.transform_options_base = .{ .unsupported = @import("../transformer/compat.zig").fromESTarget(.es5) };
    try modules.build(std.testing.io, &.{entry});
    const module = modules.moduleAtMut(modules.path_to_module.get(entry).?).?;
    const tree = &module.ast.?;
    const sem = &module.semantic.?;
    const history = &sem.scope_history;
    try std.testing.expectEqual(@as(usize, 2), history.lowered_worklet_classes.len);
    var index = try history_mod.validateAndIndex(a, tree, sem.scopes, &sem.scope_owner_map, history, null);
    defer index.deinit(a);
    try std.testing.expect(index.valid);
    const graph: Graph = .{ .ast_owner = tree, .symbols = sem.symbols.items, .scopes = sem.scopes, .scope_maps = sem.scope_maps, .owners = &sem.scope_owner_map, .ids = sem.symbol_ids, .references = sem.references, .class_self_symbols = &sem.class_self_symbol_map, .root = tree.transformed_root.?, .history_identity = @ptrCast(history) };
    const original = history.lowered_worklet_classes;
    var proof = (try prepare(a, tree, &index, original, graph)) orelse return error.MissingActualWorkletBridge;
    defer proof.deinit(a);
    for (original) |value| {
        const actual = proof.bridge(value.target.scope) orelse return error.MissingExactTargetBridge;
        try std.testing.expectEqual(value.iife.scope, actual.actual_iife_scope);
        try std.testing.expectEqual(value.constructor.scope, actual.constructor_scope);
    }
    const Reject = struct {
        fn run(allocator: std.mem.Allocator, input_tree: *const ast.Ast, input_index: *const history_mod.Index, input: []const Witness, context: Graph) !void {
            if (try prepare(allocator, input_tree, input_index, input, context)) |value| {
                var unexpected = value;
                unexpected.deinit(allocator);
                return error.UnexpectedAcceptedWorkletWitness;
            }
        }
    };
    const changed = try a.dupe(Witness, original);
    defer a.free(changed);
    // Pointer-only foreign contexts fail even when all row bytes are equal.
    try Reject.run(a, tree, &index, changed, graph);
    var foreign_tree = tree.*;
    try Reject.run(a, &foreign_tree, &index, original, graph);
    var foreign_history = history.*;
    var foreign_index = index;
    foreign_index.history = &foreign_history;
    try Reject.run(a, tree, &foreign_index, original, graph);
    const Poison = enum { foreign_source, foreign_target, foreign_creator, foreign_factory, factory_symbol, ctor_node, ctor_symbol, ctor_scope, ctor_params, ctor_body, iife_scope, iife_body, iife_parent, creator_epoch, lowered_epoch, replay, duplicate };
    for (std.enums.values(Poison)) |poison| {
        @memcpy(changed, original);
        switch (poison) {
            .foreign_source => changed[0].source = original[1].source,
            .foreign_target => changed[0].target = original[1].target,
            .foreign_creator => changed[0].creator_index = original[1].creator_index,
            .foreign_factory => changed[0].factory = original[1].factory,
            .factory_symbol => changed[0].factory.symbol = original[1].factory.symbol,
            .ctor_node => changed[0].constructor.node = original[1].constructor.node,
            .ctor_symbol => changed[0].constructor.symbol = original[1].constructor.symbol,
            .ctor_scope => changed[0].constructor.scope = original[1].constructor.scope,
            .ctor_params => changed[0].constructor.params = original[1].constructor.params,
            .ctor_body => changed[0].constructor.body = original[1].constructor.body,
            .iife_scope => changed[0].iife.scope = original[1].iife.scope,
            .iife_body => changed[0].iife.body = original[1].iife.body,
            .iife_parent => changed[0].iife.parent = original[0].wrapper_scope,
            .creator_epoch => changed[0].creator_epoch = @intCast(history.events.len + 1),
            .lowered_epoch => changed[0].lowered_epoch = @intCast(history.events.len + 1),
            .replay => changed[0].lowered_epoch = 0,
            .duplicate => changed[1] = changed[0],
        }
        var actually_changed = false;
        for (changed, original) |left, right| if (!std.meta.eql(left, right)) {
            actually_changed = true;
        };
        try std.testing.expect(actually_changed);
        history.lowered_worklet_classes = changed;
        defer history.lowered_worklet_classes = original;
        // These are semantic poisons inside the very same registered domain;
        // they must pass the pointer/backing admission before role validation.
        try std.testing.expect(index.history == history);
        try std.testing.expect(graph.history_identity == @as(*const anyopaque, @ptrCast(index.history)));
        try std.testing.expect(changed.ptr == index.history.lowered_worklet_classes.ptr);
        try std.testing.expectEqual(changed.len, index.history.lowered_worklet_classes.len);
        try Reject.run(a, tree, &index, changed, graph);
        history.lowered_worklet_classes = original;
    }
    // Actual current graph slots are independent of witness claims.
    const altered_symbols = try a.dupe(symbols.Symbol, graph.symbols);
    defer a.free(altered_symbols);
    var altered_graph = graph;
    altered_graph.symbols = altered_symbols;
    altered_symbols[@backingInt(original[0].target.self)].origin_scope = original[0].iife.scope;
    try Reject.run(a, tree, &index, original, altered_graph);
    @memcpy(altered_symbols, graph.symbols);
    altered_symbols[@backingInt(original[0].target.self)].scope_id = original[0].factory.scope;
    try Reject.run(a, tree, &index, original, altered_graph);
    const ClassRolePoison = enum { kind, class_flag, const_flag, preserved_name_flag };
    for ([_]SymbolId{ original[0].source.self, original[0].target.self }) |self_sid| {
        for (std.enums.values(ClassRolePoison)) |poison| {
            @memcpy(altered_symbols, graph.symbols);
            const changed_self = &altered_symbols[@backingInt(self_sid)];
            switch (poison) {
                .kind => changed_self.kind = .variable_var,
                .class_flag => changed_self.decl_flags.is_class = false,
                .const_flag => changed_self.decl_flags.is_const = false,
                .preserved_name_flag => changed_self.decl_flags.preserve_class_name = false,
            }
            try Reject.run(a, tree, &index, original, altered_graph);
        }
    }
    @memcpy(altered_symbols, graph.symbols);
    altered_symbols[@backingInt(original[0].factory.symbol)].kind = .variable_var;
    try Reject.run(a, tree, &index, original, altered_graph);
    @memcpy(altered_symbols, graph.symbols);
    altered_symbols[@backingInt(original[0].factory.symbol)].decl_flags.is_function = false;
    try Reject.run(a, tree, &index, original, altered_graph);
    const altered_ids = try a.dupe(?u32, graph.ids);
    defer a.free(altered_ids);
    altered_graph = graph;
    altered_graph.ids = altered_ids;
    const ctor_name = original[0].constructor.name;
    altered_ids[@backingInt(ctor_name)] = @backingInt(original[1].target.self);
    try Reject.run(a, tree, &index, original, altered_graph);
    const altered_scopes = try a.dupe(scopes.Scope, graph.scopes);
    defer a.free(altered_scopes);
    altered_graph = graph;
    altered_graph.scopes = altered_scopes;
    altered_scopes[original[0].target.scope.toIndex()].parent = original[0].wrapper_scope;
    try Reject.run(a, tree, &index, original, altered_graph);
    // Source headers remain immutable birth edges, even after becoming dead.
    const source_extra = tree.getNode(original[0].source.node).data.extra;
    const source_body_slot = source_extra + ast.ClassExtra.body;
    const saved_body = tree.extra_data.items[source_body_slot];
    tree.extra_data.items[source_body_slot] = @backingInt(original[1].source.body);
    defer tree.extra_data.items[source_body_slot] = saved_body;
    try Reject.run(a, tree, &index, original, graph);
    tree.extra_data.items[source_body_slot] = saved_body;
    const Oom = struct {
        fn run(allocator: std.mem.Allocator, input_tree: *const ast.Ast, input_index: *const history_mod.Index, input: []const Witness, context: Graph) !void {
            var result = (try prepare(allocator, input_tree, input_index, input, context)) orelse return error.UnexpectedProofRejection;
            defer result.deinit(allocator);
        }
    };
    try std.testing.expect(history.lowered_worklet_classes.ptr == original.ptr);
    const Snapshot = struct {
        header: *const ast.Ast,
        root: ?NodeIndex,
        nodes: []const ast.Node,
        extra: []const u32,
        strings: []const u8,
        ids: []const ?u32,
        symbols: []const symbols.Symbol,
        scopes: []const scopes.Scope,
        references: []const symbols.Reference,
        history_backings: history_mod.History,
        history_values: history_mod.History,
    };
    const Cow = struct {
        fn release(allocator: std.mem.Allocator, value: history_mod.History) void {
            inline for (@typeInfo(history_mod.History).@"struct".field_names) |name| allocator.free(@field(value, name));
        }
        fn compare(snapshot: Snapshot, input_tree: *const ast.Ast, input_index: *const history_mod.Index, context: Graph) !void {
            const equal = @import("test_node_equality.zig");
            try std.testing.expect(snapshot.header == input_tree);
            try std.testing.expectEqual(snapshot.root, input_tree.transformed_root);
            try equal.expectEqualDeep(snapshot.nodes, input_tree.nodes.items);
            try equal.expectEqualDeep(snapshot.extra, input_tree.extra_data.items);
            try equal.expectEqualDeep(snapshot.strings, input_tree.string_table.items);
            try equal.expectEqualDeep(snapshot.ids, context.ids);
            try equal.expectEqualDeep(snapshot.symbols, context.symbols);
            try equal.expectEqualDeep(snapshot.scopes, context.scopes);
            try equal.expectEqualDeep(snapshot.references, context.references);
            inline for (@typeInfo(history_mod.History).@"struct".field_names) |name| {
                const actual = @field(input_index.history.*, name);
                const before = @field(snapshot.history_backings, name);
                try std.testing.expect(actual.ptr == before.ptr);
                try std.testing.expectEqual(before.len, actual.len);
                try equal.expectEqualDeep(@field(snapshot.history_values, name), actual);
            }
        }
        fn cloneAndPrepare(allocator: std.mem.Allocator, input_tree: *const ast.Ast, input_index: *const history_mod.Index, context: Graph) !void {
            var recorder = try history_mod.Recorder.fromHistory(allocator, input_index.history.*);
            defer recorder.deinit(allocator);
            const copied = try recorder.finish(allocator);
            defer release(allocator, copied);
            try std.testing.expect(copied.worklet_class_creators.ptr != input_index.history.worklet_class_creators.ptr);
            try std.testing.expect(copied.lowered_worklet_classes.ptr != input_index.history.lowered_worklet_classes.ptr);
            const equal = @import("test_node_equality.zig");
            try equal.expectEqualDeep(input_index.history.worklet_class_creators, copied.worklet_class_creators);
            try equal.expectEqualDeep(input_index.history.lowered_worklet_classes, copied.lowered_worklet_classes);
            var copied_index = try history_mod.validateAndIndex(allocator, input_tree, context.scopes, context.owners, &copied, null);
            defer copied_index.deinit(allocator);
            try std.testing.expect(copied_index.valid);
            var copied_context = context;
            copied_context.history_identity = @ptrCast(&copied);
            var prepared = (try prepare(allocator, input_tree, &copied_index, copied.lowered_worklet_classes, copied_context)) orelse return error.CowLostExactWorkletBridge;
            defer prepared.deinit(allocator);
            try std.testing.expectEqual(input_index.history.lowered_worklet_classes.len, prepared.entries.len);
        }
    };
    var baseline_recorder = try history_mod.Recorder.fromHistory(a, history.*);
    defer baseline_recorder.deinit(a);
    const history_values = try baseline_recorder.finish(a);
    defer Cow.release(a, history_values);
    const before_nodes = try a.dupe(ast.Node, tree.nodes.items);
    defer a.free(before_nodes);
    const before_extra = try a.dupe(u32, tree.extra_data.items);
    defer a.free(before_extra);
    const before_strings = try a.dupe(u8, tree.string_table.items);
    defer a.free(before_strings);
    const before_ids = try a.dupe(?u32, graph.ids);
    defer a.free(before_ids);
    const before_symbols = try a.dupe(symbols.Symbol, graph.symbols);
    defer a.free(before_symbols);
    const before_scopes = try a.dupe(scopes.Scope, graph.scopes);
    defer a.free(before_scopes);
    const before_references = try a.dupe(symbols.Reference, graph.references);
    defer a.free(before_references);
    const snapshot: Snapshot = .{ .header = tree, .root = tree.transformed_root, .nodes = before_nodes, .extra = before_extra, .strings = before_strings, .ids = before_ids, .symbols = before_symbols, .scopes = before_scopes, .references = before_references, .history_backings = history.*, .history_values = history_values };
    const Sweep = struct {
        fn run(comptime callback: anytype, backing: std.mem.Allocator, args: anytype, input_tree: *const ast.Ast, input_index: *const history_mod.Index, context: Graph, before: Snapshot, label: []const u8) !void {
            // Resizes/remaps depend on the backing allocator's physical layout.
            // Pin them off for BOTH the baseline and every failure window.
            var baseline = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
            const baseline_result = @call(.auto, callback, .{baseline.allocator()} ++ args);
            try Cow.compare(before, input_tree, input_index, context);
            try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
            try baseline_result;
            try std.testing.expect(!baseline.has_induced_failure);
            const windows = baseline.alloc_index;
            try std.testing.expect(windows > 0);
            for (0..windows + 1) |window| {
                var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = window, .resize_fail_index = 0 });
                const outcome = @call(.auto, callback, .{failing.allocator()} ++ args);
                // Check original data after target cleanup on every result.
                try Cow.compare(before, input_tree, input_index, context);
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
                if (outcome) |_| {
                    try std.testing.expect(!failing.has_induced_failure);
                    try std.testing.expectEqual(windows, window);
                    std.debug.print("WORKLET_OOM {s} resize_fail_index=0 failure_windows={d} first_success={d} sourceUnchanged=true leakBytes=0\n", .{ label, windows, window });
                    return;
                } else |err| {
                    try std.testing.expect(err == error.OutOfMemory);
                    try std.testing.expect(failing.has_induced_failure);
                    try std.testing.expect(window < windows);
                }
            }
            return error.MissingNaturalWorkletOomSuccess;
        }
    };
    try Sweep.run(Oom.run, a, .{ tree, &index, original, graph }, tree, &index, graph, snapshot, "prepare");
    try Sweep.run(Cow.cloneAndPrepare, a, .{ tree, &index, graph }, tree, &index, graph, snapshot, "historyCOW");
    // A disk-style roundtrip owns a distinct AST header and all graph/History
    // backings. No outer graph pointer is serialized or reused as authority.
    var wire_arena = std.heap.ArenaAllocator.init(a);
    defer wire_arena.deinit();
    const wire = wire_arena.allocator();
    var ast_bytes: std.ArrayList(u8) = .empty;
    var semantic_bytes: std.ArrayList(u8) = .empty;
    const ast_codec = @import("../parser/ast_codec.zig");
    const semantic_codec = @import("../bundler/semantic_codec.zig");
    try ast_codec.serialize(tree, &ast_bytes, wire);
    try semantic_codec.serialize(sem, &semantic_bytes, wire);
    var decoded_tree = try ast_codec.deserialize(ast_bytes.items, wire);
    var decoded_semantic = try semantic_codec.deserialize(semantic_bytes.items, wire);
    const decoded_history = &decoded_semantic.scope_history;
    try std.testing.expect(&decoded_tree != tree);
    try std.testing.expect(decoded_tree.nodes.items.ptr != tree.nodes.items.ptr);
    try std.testing.expect(decoded_semantic.symbol_ids.ptr != sem.symbol_ids.ptr);
    try std.testing.expect(decoded_history.worklet_class_creators.ptr != history.worklet_class_creators.ptr);
    try std.testing.expect(decoded_history.lowered_worklet_classes.ptr != history.lowered_worklet_classes.ptr);
    try @import("test_node_equality.zig").expectEqualDeep(history.worklet_class_creators, decoded_history.worklet_class_creators);
    try @import("test_node_equality.zig").expectEqualDeep(history.lowered_worklet_classes, decoded_history.lowered_worklet_classes);
    // wire_arena owns the index/proof arrays too; no individual arena cleanup.
    var decoded_index = try history_mod.validateAndIndex(wire, &decoded_tree, decoded_semantic.scopes, &decoded_semantic.scope_owner_map, decoded_history, null);
    try std.testing.expect(decoded_index.valid);
    const decoded_graph: Graph = .{ .ast_owner = &decoded_tree, .symbols = decoded_semantic.symbols.items, .scopes = decoded_semantic.scopes, .scope_maps = decoded_semantic.scope_maps, .owners = &decoded_semantic.scope_owner_map, .ids = decoded_semantic.symbol_ids, .references = decoded_semantic.references, .class_self_symbols = &decoded_semantic.class_self_symbol_map, .root = decoded_tree.transformed_root orelse return error.MissingDecodedRoot, .history_identity = @ptrCast(decoded_history) };
    const decoded_proof = (try prepare(wire, &decoded_tree, &decoded_index, decoded_history.lowered_worklet_classes, decoded_graph)) orelse return error.DecodedWorkletBridgeRejected;
    try std.testing.expectEqual(original.len, decoded_proof.entries.len);
    for (original) |value| {
        const restored = decoded_proof.bridge(value.target.scope) orelse return error.MissingDecodedTargetBridge;
        try std.testing.expectEqual(value.iife.scope, restored.actual_iife_scope);
        try std.testing.expectEqual(value.constructor.scope, restored.constructor_scope);
    }
    try Cow.compare(snapshot, tree, &index, graph);
}
