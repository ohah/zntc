//! A generic lookup observed unresolved in the initial source analyzer.
//! This grants no intrinsic/global authority and never selects a SymbolId.
const ast = @import("../parser/ast.zig");
const scope = @import("scope.zig");
pub const EmptyArrowElision = struct { owner: ast.NodeIndex, source: ast.Node };
pub const StaticBlockTransfer = struct {
    source_owner: @import("scope_frame_history.zig").Owner,
    target_owner: @import("scope_frame_history.zig").Owner,
    // History authenticates the owner header; these edges are captured by the
    // actual producer and checked against its final AST, not inferred at birth.
    source_body: ast.NodeIndex,
    parameters: ast.NodeIndex,
    output_body: ast.NodeIndex = .none,
    birth_epoch: u32,
};
pub const ClassHeritageTransfer = struct {
    owner: @import("scope_frame_history.zig").Owner,
    class_scope: scope.ScopeId,
    heritage: ast.NodeIndex,
    evaluation_scope: scope.ScopeId,
    capture_epoch: u32,
};
pub const ClassInitializerTransfer = struct {
    source_index: u32,
    target_owner: @import("scope_frame_history.zig").Owner,
    parameters: ast.NodeIndex,
    body: ast.NodeIndex,
    owner_epoch: u32,
};
pub const ScopeMove = struct {
    node: ast.NodeIndex,
    source_node: ast.NodeIndex,
    from: scope.ScopeId,
    to: scope.ScopeId,
    from_frame: scope.Scope,
    to_frame: scope.Scope,
    reason: enum(u32) { lowerer_scope_relocation, empty_arrow_scope_elision, static_block_environment_transfer, generator_environment_transfer, class_heritage_evaluation, class_initializer_environment_transfer, class_key_evaluation },
    elision: ?EmptyArrowElision = null,
    static_block: ?StaticBlockTransfer = null,
    generator: ?@import("generator_environment_transfer.zig").Transfer = null,
    class_heritage: ?ClassHeritageTransfer = null,
    class_initializer: ?ClassInitializerTransfer = null,
    class_key: ?@import("class_key_evaluation.zig").Transfer = null,
    frame_epoch: u32 = 0,
};

pub const Origin = struct {
    tag: ast.Node.Tag,
    name: ast.StringRef,
    span: @import("../lexer/token.zig").Span,
    flags: @import("symbol.zig").ReferenceFlags,
    source_scope: scope.ScopeId,
    source_frame: scope.Scope,
    execution_scope: scope.ScopeId,
    execution_frame: scope.Scope,
    scope_moves: []const ScopeMove = &.{},
    jsx_reference: ?@import("scope_frame_history.zig").Owner = null,
};

pub fn sameFrame(a: scope.Scope, b: scope.Scope) bool {
    return a.parent == b.parent and a.kind == b.kind and a.is_strict == b.is_strict and
        a.subtree_has_direct_eval == b.subtree_has_direct_eval and a.subtree_has_with == b.subtree_has_with;
}

pub fn validate(
    tree: *const ast.Ast,
    parser_node_count: u32,
    symbol_ids: []const ?u32,
    scopes: []const scope.Scope,
    unresolved: *const @import("std").AutoHashMapUnmanaged(u32, void),
    provenance: *const @import("node_scope_provenance.zig").Map,
    history: *const @import("scope_frame_history.zig").Index,
) bool {
    const std = @import("std");
    var entries = provenance.iterator();
    while (entries.next()) |entry| {
        const origin = entry.value_ptr.source_external orelse continue;
        const raw = @backingInt(entry.key_ptr.*);
        const source = @backingInt(entry.value_ptr.source_node);
        if (entry.value_ptr.external_import != null or raw >= tree.nodes.items.len or raw >= symbol_ids.len or symbol_ids[raw] != null or
            source >= parser_node_count or !unresolved.contains(source) or
            origin.source_scope.isNone() or origin.source_scope.toIndex() >= scopes.len or
            origin.execution_scope.isNone() or origin.execution_scope.toIndex() >= scopes.len or
            !sameFrame(origin.source_frame, history.frameAt(origin.source_scope, 0) orelse return false) or
            !sameFrame(origin.execution_frame, history.frameAt(origin.execution_scope, 0) orelse return false)) return false;
        const node = tree.nodes.items[raw];
        switch (node.tag) {
            .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
            else => return false,
        }
        if (origin.jsx_reference) |source_jsx| {
            if (origin.tag != .jsx_identifier or node.tag != .identifier_reference or source_jsx.node != entry.value_ptr.source_node or source_jsx.tag != .jsx_identifier or
                !std.meta.eql(source_jsx.span, origin.span) or source_jsx.words[0] != origin.name.start or source_jsx.words[1] != origin.name.end or
                !origin.flags.read or origin.flags.write or origin.flags.declare or origin.flags.type_context or origin.flags.value_as_type) return false;
            const actual_source = (@import("scope_frame_history.zig").Owner.capture(tree, source_jsx.node) catch return false) orelse return false;
            if (!std.meta.eql(actual_source, source_jsx)) return false;
        } else if (node.tag != origin.tag) return false;
        if (!std.meta.eql(node.data.string_ref, origin.name) or !std.meta.eql(node.span, origin.span)) return false;
        const execution = enclosingAt(history, origin.source_scope, 0, scopes.len) orelse return false;
        if (execution != origin.execution_scope) return false;
        var current = origin.source_scope;
        var current_execution = origin.execution_scope;
        for (origin.scope_moves, 0..) |move, move_index| {
            if (move.source_node != entry.value_ptr.source_node or
                move.node.isNone() or @backingInt(move.node) >= tree.nodes.items.len or
                move.from != current or move.to.isNone() or move.to.toIndex() >= scopes.len or
                move.from.isNone() or move.from.toIndex() >= scopes.len or move.from == move.to or
                !sameFrame(move.from_frame, history.frameAt(move.from, move.frame_epoch) orelse return false) or
                !sameFrame(move.to_frame, history.frameAt(move.to, move.frame_epoch) orelse return false)) return false;
            if ((move.reason == .class_initializer_environment_transfer) != (move.class_initializer != null) or
                (move.reason == .class_key_evaluation) != (move.class_key != null)) return false;
            switch (move.reason) {
                .lowerer_scope_relocation => {
                    if (move.elision != null or move.static_block != null or move.generator != null or move.class_heritage != null or move.class_initializer != null) return false;
                    if (!descendantAt(history, move.from, current_execution, move.frame_epoch, scopes.len) or
                        !descendantAt(history, move.to, current_execution, move.frame_epoch, scopes.len)) return false;
                },
                .static_block_environment_transfer => {
                    const transfer = move.static_block orelse return false;
                    if (current_execution != move.from or move.elision != null or move.generator != null or move.class_heritage != null or !validStaticBlockTransfer(tree, history, origin, move, transfer)) return false;
                    // The validated producer replaces this exact execution
                    // environment. Later lexical moves stay inside its target;
                    // the immutable initial execution witness is unchanged.
                    current_execution = move.to;
                },
                .class_initializer_environment_transfer => {
                    const transfer = move.class_initializer orelse return false;
                    if (move.elision != null or move.static_block != null or move.generator != null or move.class_heritage != null or current_execution != move.from or
                        !validClassInitializer(tree, history, origin, move, transfer)) return false;
                    current_execution = move.to;
                },
                .generator_environment_transfer => {
                    const transfer = move.generator orelse return false;
                    for (origin.scope_moves[0..move_index]) |earlier| if (earlier.generator) |consumed| {
                        if (consumed.source.owner.node == transfer.source.owner.node) return false;
                    };
                    if (move.elision != null or move.static_block != null or move.class_heritage != null or !@import("generator_environment_transfer.zig").validates(tree, history, parser_node_count, entry.value_ptr.source_node, origin.flags, entry.value_ptr.with_environment, origin.source_scope, origin.execution_scope, move.from, move.to, move.frame_epoch, scopes.len, transfer)) return false;
                },
                .class_key_evaluation => {
                    const transfer = move.class_key orelse return false;
                    if (entry.value_ptr.with_environment or move.elision != null or move.static_block != null or move.generator != null or move.class_heritage != null or move.class_initializer != null or
                        !@import("class_key_evaluation.zig").validates(tree, history, parser_node_count, origin, move, transfer)) return false;
                    current_execution = move.to;
                },
                .class_heritage_evaluation => {
                    const transfer = move.class_heritage orelse return false;
                    if (move.elision != null or move.static_block != null or move.generator != null or !validClassHeritage(tree, history, origin, move, transfer, parser_node_count)) return false;
                },
                .empty_arrow_scope_elision => {
                    if (move.static_block != null or move.generator != null or move.class_heritage != null) return false;
                    const elision = move.elision orelse return false;
                    if (elision.owner.isNone() or @backingInt(elision.owner) >= tree.nodes.items.len or
                        elision.source.tag != .arrow_function_expression or
                        !tree.hasExtra(elision.source.data.extra, ast.ArrowExtra.flags) or
                        tree.functionParams(elision.source).len != 0 or
                        tree.readExtra(elision.source.data.extra, ast.ArrowExtra.flags) & ast.ArrowFlags.is_async != 0 or
                        move.from_frame.kind != .function or move.from_frame.parent != move.to or
                        move.from_frame.symbol_count != 0 or move.from_frame.blocksMangling() or
                        move.from_frame.is_strict != move.to_frame.is_strict or entry.value_ptr.with_environment) return false;
                },
            }
            current = move.to;
        }
        if (entry.value_ptr.scope != current) return false;
    }
    return true;
}

fn validClassInitializer(tree: *const ast.Ast, index: *const @import("scope_frame_history.zig").Index, origin: Origin, move: ScopeMove, transfer: ClassInitializerTransfer) bool {
    const std = @import("std");
    const H = @import("scope_frame_history.zig");
    if (transfer.source_index >= index.history.source_initializers.len or transfer.owner_epoch == 0 or transfer.owner_epoch > index.history.events.len) return false;
    const source = index.history.source_initializers[transfer.source_index];
    if (source.scope != move.from or source.leaf.node != move.source_node or source.leaf.tag != origin.tag or
        !std.meta.eql(source.leaf.span, origin.span) or source.leaf.words[0] != origin.name.start or source.leaf.words[1] != origin.name.end or
        source.initializer.node.isNone() or @backingInt(source.initializer.node) >= tree.nodes.items.len or
        (source.field.tag != .property_definition and source.field.tag != .accessor_property) or
        move.from_frame.kind != .class_body or !move.from_frame.is_strict or
        move.to_frame.kind != .function or !move.to_frame.is_strict or
        (move.from_frame.subtree_has_direct_eval and !move.to_frame.subtree_has_direct_eval) or
        (move.from_frame.subtree_has_with and !move.to_frame.subtree_has_with)) return false;
    var source_owner: ?H.OwnerBinding = null;
    for (index.history.source_owners) |binding| {
        if (binding.scope == source.scope and std.meta.eql(binding.owner, source.class_owner)) source_owner = binding;
    }
    const original_owner = source_owner orelse return false;
    const class_iife = move.from_frame.parent == move.to;
    if (transfer.owner_epoch > move.frame_epoch) {
        if (!class_iife) return false;
        var reserved = false;
        for (index.history.events[0..move.frame_epoch]) |prior| {
            if (prior.kind == .birth and prior.scope == move.to and prior.owner_after == null and prior.actor.role == .editor and prior.actor.module_index == null) reserved = true;
        }
        if (!reserved) return false;
    }
    const event = index.history.events[transfer.owner_epoch - 1];
    if ((event.kind != .birth and event.kind != .owner) or event.scope != move.to or event.owner_before != null or
        event.actor.role != .editor or event.actor.module_index != null or event.owner_after == null or
        !std.meta.eql(event.owner_after.?, transfer.target_owner) or
        event.owner_edges.parameters != transfer.parameters or event.owner_edges.body != transfer.body or
        transfer.target_owner.tag != .function_expression or transfer.target_owner.node.isNone() or
        @backingInt(transfer.target_owner.node) >= tree.nodes.items.len) return false;
    const target = tree.getNode(transfer.target_owner.node);
    const current = H.Owner.capture(tree, transfer.target_owner.node) catch return false;
    if (current == null or !std.meta.eql(current.?, transfer.target_owner) or (!class_iife and !std.meta.eql(target.span, source.initializer.span)) or
        !tree.hasExtra(target.data.extra, ast.FunctionExtra.flags) or tree.readExtraNode(target.data.extra, ast.FunctionExtra.name) != .none or
        tree.readExtraNode(target.data.extra, ast.FunctionExtra.params) != transfer.parameters or tree.readExtraNode(target.data.extra, ast.FunctionExtra.body) != transfer.body or
        tree.readExtra(target.data.extra, ast.FunctionExtra.flags) != 0 or transfer.parameters.isNone() or @backingInt(transfer.parameters) >= tree.nodes.items.len or
        tree.getNode(transfer.parameters).tag != .formal_parameters or tree.functionParams(target).len != (if (class_iife and !original_owner.edges.heritage.isNone()) @as(usize, 1) else 0) or
        transfer.body.isNone() or @backingInt(transfer.body) >= tree.nodes.items.len or tree.getNode(transfer.body).tag != .block_statement) return false;
    return true;
}

pub fn transferredClassInitializer(a: @import("std").mem.Allocator, origin: Origin, node: ast.NodeIndex, source_node: ast.NodeIndex, from: scope.ScopeId, to: scope.ScopeId, scopes: []const scope.Scope, frame_epoch: u32, transfer: ClassInitializerTransfer) !Origin {
    const next = try moved(a, origin, node, source_node, from, to, scopes, frame_epoch);
    if (from == to) return next;
    const moves = @constCast(next.scope_moves);
    moves[moves.len - 1].reason = .class_initializer_environment_transfer;
    moves[moves.len - 1].class_initializer = transfer;
    return next;
}

pub fn classKey(a: @import("std").mem.Allocator, origin: Origin, node: ast.NodeIndex, source_node: ast.NodeIndex, from: scope.ScopeId, to: scope.ScopeId, scopes: []const scope.Scope, frame_epoch: u32, transfer: @import("class_key_evaluation.zig").Transfer) !Origin {
    const next = try moved(a, origin, node, source_node, from, to, scopes, frame_epoch);
    if (from == to) return next;
    const moves = @constCast(next.scope_moves);
    moves[moves.len - 1].reason = .class_key_evaluation;
    moves[moves.len - 1].class_key = transfer;
    return next;
}

/// Record the existing lowerer's explicit same-node use-scope handoff.
pub fn moved(a: @import("std").mem.Allocator, origin: Origin, node: ast.NodeIndex, source_node: ast.NodeIndex, from: scope.ScopeId, to: scope.ScopeId, scopes: []const scope.Scope, frame_epoch: u32) !Origin {
    var next = origin;
    if (from == to) return next;
    const moves = try a.alloc(ScopeMove, origin.scope_moves.len + 1);
    @memcpy(moves[0..origin.scope_moves.len], origin.scope_moves);
    moves[origin.scope_moves.len] = .{ .node = node, .source_node = source_node, .from = from, .to = to, .from_frame = scopes[from.toIndex()], .to_frame = scopes[to.toIndex()], .reason = .lowerer_scope_relocation, .frame_epoch = frame_epoch };
    next.scope_moves = moves;
    return next;
}

/// Allocation reservations consume actual output lookups, never recover IDs.
/// The identity proof is a separate caller obligation; over-reservation cannot
/// grant a binding/global role. Names are copied before later AST string growth.
pub fn reserveOutputNames(a: @import("std").mem.Allocator, tree: *const ast.Ast, root: ast.NodeIndex, ids: []const ?u32, origins: *const @import("node_scope_provenance.zig").Map, reserved: *@import("std").StringHashMapUnmanaged(void)) !void {
    const nodes = try @import("reference_walk.zig").collectIdentifierReferences(a, tree, root);
    defer a.free(nodes);
    for (nodes) |node| {
        const raw = @backingInt(node);
        const entry = origins.get(node) orelse continue;
        if (entry.source_external == null and entry.external_import == null) continue;
        if (raw >= ids.len or ids[raw] != null) continue;
        const actual = tree.getNode(node);
        const expected_name = if (entry.source_external) |origin| origin.name else entry.external_import.?.before_name;
        if (!@import("std").meta.eql(actual.data.string_ref, expected_name)) continue;
        const spelling = tree.getText(actual.data.string_ref);
        const decoded = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, spelling);
        defer if (decoded.ptr != spelling.ptr) a.free(decoded);
        if (reserved.contains(decoded)) continue;
        const stable = try a.dupe(u8, decoded);
        errdefer a.free(stable);
        try reserved.put(a, stable, {});
    }
}

pub fn elided(a: @import("std").mem.Allocator, origin: Origin, node: ast.NodeIndex, source_node: ast.NodeIndex, from: scope.ScopeId, to: scope.ScopeId, scopes: []const scope.Scope, owner: ast.NodeIndex, before: ast.Node, frame_epoch: u32) !Origin {
    const next = try moved(a, origin, node, source_node, from, to, scopes, frame_epoch);
    if (from == to) return next;
    const moves = @constCast(next.scope_moves);
    moves[moves.len - 1].reason = .empty_arrow_scope_elision;
    moves[moves.len - 1].elision = .{ .owner = owner, .source = before };
    return next;
}

fn enclosingAt(history: *const @import("scope_frame_history.zig").Index, start: scope.ScopeId, epoch: u32, count: usize) ?scope.ScopeId {
    var current = start;
    var fuel = count + 1;
    while (!current.isNone() and fuel > 0) : (fuel -= 1) {
        const frame = history.frameAt(current, epoch) orelse return null;
        switch (frame.kind) {
            .global, .module, .function, .class_body, .class_static_block => return current,
            else => current = frame.parent,
        }
    }
    return null;
}
fn descendantAt(history: *const @import("scope_frame_history.zig").Index, start: scope.ScopeId, target: scope.ScopeId, epoch: u32, count: usize) bool {
    var current = start;
    var fuel = count + 1;
    while (!current.isNone() and fuel > 0) : (fuel -= 1) {
        if (current == target) return true;
        const frame = history.frameAt(current, epoch) orelse return false;
        current = frame.parent;
    }
    return false;
}

/// The static-block producer replaces one real var environment with a distinct
/// strict function. Generic lexical relocation cannot authorize that boundary.
fn validStaticBlockTransfer(tree: *const ast.Ast, history: *const @import("scope_frame_history.zig").Index, origin: Origin, move: ScopeMove, transfer: StaticBlockTransfer) bool {
    const std = @import("std");
    if (origin.execution_scope != move.from or move.from_frame.kind != .class_static_block or
        move.to_frame.kind != .function or !move.from_frame.is_strict or !move.to_frame.is_strict or
        move.from_frame.subtree_has_direct_eval != move.to_frame.subtree_has_direct_eval or
        move.from_frame.subtree_has_with != move.to_frame.subtree_has_with or
        transfer.source_owner.tag != .static_block or transfer.target_owner.tag != .function_expression or
        transfer.source_body.isNone() or @backingInt(transfer.source_body) >= tree.nodes.items.len or transfer.source_owner.words[0] != @backingInt(transfer.source_body) or
        transfer.birth_epoch == 0 or transfer.birth_epoch > move.frame_epoch or
        transfer.birth_epoch > history.history.events.len) return false;
    var initial: ?@import("scope_frame_history.zig").Owner = null;
    for (history.history.source_owners) |binding| {
        if (binding.scope != move.from or binding.owner.tag != .static_block) continue;
        if (initial != null) return false;
        initial = binding.owner;
    }
    var current_owner_witness = initial orelse return false;
    for (history.history.events[0..move.frame_epoch]) |event| {
        if (event.scope != move.from or event.kind != .owner) continue;
        const before = event.owner_before orelse continue;
        if (!std.meta.eql(before, current_owner_witness)) continue;
        const after = event.owner_after orelse return false;
        if (event.actor.role != .editor or event.actor.module_index != null or
            after.tag != .static_block or !std.meta.eql(after.span, current_owner_witness.span)) return false;
        current_owner_witness = after;
    }
    if (!std.meta.eql(current_owner_witness, transfer.source_owner)) return false;
    const birth = history.history.events[transfer.birth_epoch - 1];
    if (birth.kind != .birth or birth.scope != move.to or birth.actor.role != .editor or
        birth.actor.module_index != null or birth.owner_after == null or
        !std.meta.eql(birth.owner_after.?, transfer.target_owner) or
        transfer.target_owner.node.isNone() or @backingInt(transfer.target_owner.node) >= tree.nodes.items.len or
        !std.meta.eql(transfer.source_owner.span, transfer.target_owner.span)) return false;
    const target = tree.getNode(transfer.target_owner.node);
    const current_owner = @import("scope_frame_history.zig").Owner.capture(tree, transfer.target_owner.node) catch return false;
    if (current_owner == null or !std.meta.eql(current_owner.?, transfer.target_owner)) return false;
    if (target.tag != .function_expression or target.data.extra >= tree.extra_data.items.len or
        ast.FunctionExtra.flags >= tree.extra_data.items.len - target.data.extra or
        tree.readExtraNode(target.data.extra, ast.FunctionExtra.name) != .none or
        tree.readExtraNode(target.data.extra, ast.FunctionExtra.params) != transfer.parameters or
        tree.readExtraNode(target.data.extra, ast.FunctionExtra.body) != transfer.output_body or
        tree.readExtra(target.data.extra, ast.FunctionExtra.flags) != 0 or
        transfer.parameters.isNone() or @backingInt(transfer.parameters) >= tree.nodes.items.len or
        transfer.output_body.isNone() or @backingInt(transfer.output_body) >= tree.nodes.items.len or
        tree.getNode(transfer.parameters).tag != .formal_parameters or tree.functionParams(target).len != 0 or
        tree.getNode(transfer.output_body).tag != .block_statement) return false;
    return true;
}

pub fn transferredStaticBlock(a: @import("std").mem.Allocator, origin: Origin, node: ast.NodeIndex, source_node: ast.NodeIndex, from: scope.ScopeId, to: scope.ScopeId, scopes: []const scope.Scope, frame_epoch: u32, transfer: StaticBlockTransfer) !Origin {
    const next = try moved(a, origin, node, source_node, from, to, scopes, frame_epoch);
    if (from == to) return next;
    const moves = @constCast(next.scope_moves);
    moves[moves.len - 1].reason = .static_block_environment_transfer;
    moves[moves.len - 1].static_block = transfer;
    return next;
}

test "static block external handoff preserves actual owners and rejects foreign paired or replayed boundaries" {
    const std = @import("std");
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const source = "class First{static{globalThis.first=Object.keys({a:7}).length}}class Second{static{globalThis.second=Object.keys({b:8}).length}}console.log(globalThis.first,globalThis.second);";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    const parser_node_count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es2015);
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var transformer = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es2015) });
    try transformer.initSymbolIdsOwned(analyzer.ast, analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.helper_scope_map = analyzer.helper_scope_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.scope_history = analyzer.scope_history;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.record_explicit_global_references = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var data: Data = .{
        .symbols = edited.symbols,
        .scopes = edited.scopes,
        .scope_maps = edited.scope_maps,
        .scope_owner_map = edited.scope_owner_map,
        .symbol_ids = edited.symbol_ids,
        .references = edited.references,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
        .helper_scope_map = edited.helper_scope_map,
        .node_scope_provenance = edited.node_scope_provenance,
        .scope_history = edited.scope_history,
        .source_owned_retirements = edited.source_owned_retirements,
    };
    const Check = struct {
        fn run(alloc: std.mem.Allocator, tree: *const ast.Ast, output_root: ast.NodeIndex, parser_count: u32, sem: *const Data, unresolved: *const std.AutoHashMapUnmanaged(u32, void), producer: *const Transformer) !bool {
            var report = try @import("../transformer/symbol_coverage.zig").checkOutputNormalFormQuiet(alloc, tree, output_root, parser_count, sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, producer.helper_ref_nodes.items, &sem.helper_scope_map, unresolved, &producer.explicit_global_reference_nodes, &producer.reference_origin_map, .{ .pre_transform_scope_count = sem.scope_history.source_scopes.len }, &sem.source_owned_retirements, .{
                .node_scope_provenance = &sem.node_scope_provenance,
                .scope_history = &sem.scope_history,
                .runtime_helper_symbols = &producer.runtime_helper_symbol_ids,
                .class_self_symbols = &producer.class_self_symbol_map,
            });
            defer report.deinit(alloc);
            return report.hasCompleteOutputIdentityBeforeNames();
        }
    };
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    const Selected = struct { node: ast.NodeIndex, entry: @import("node_scope_provenance.zig").Entry, move_index: usize };
    var selected: ?Selected = null;
    var other: ?Selected = null;
    var entries = data.node_scope_provenance.iterator();
    while (entries.next()) |entry| {
        const origin = entry.value_ptr.source_external orelse continue;
        for (origin.scope_moves, 0..) |move, index| {
            const transfer = move.static_block orelse continue;
            if (selected == null) {
                selected = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .move_index = index };
            } else if (transfer.source_owner.node != selected.?.entry.source_external.?.scope_moves[selected.?.move_index].static_block.?.source_owner.node) {
                other = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .move_index = index };
            }
        }
    }
    const chosen = selected orelse return error.TestUnexpectedResult;
    const peer = other orelse return error.TestUnexpectedResult;
    const original = chosen.entry.source_external.?;
    const peer_move = peer.entry.source_external.?.scope_moves[peer.move_index];
    const moves = try a.dupe(ScopeMove, original.scope_moves);
    for (0..12) |poison| {
        @memcpy(moves, original.scope_moves);
        var wrong = chosen.entry;
        var changed = original;
        changed.scope_moves = moves;
        const move = &moves[chosen.move_index];
        const transfer = &move.static_block.?;
        switch (poison) {
            0 => transfer.source_owner = peer_move.static_block.?.source_owner,
            1 => transfer.target_owner = peer_move.static_block.?.target_owner,
            2 => transfer.source_body = peer_move.static_block.?.source_body,
            3 => transfer.parameters = peer_move.static_block.?.parameters,
            4 => transfer.output_body = peer_move.static_block.?.output_body,
            5 => transfer.birth_epoch = 0,
            6 => transfer.birth_epoch = peer_move.static_block.?.birth_epoch,
            7 => move.from_frame.is_strict = false,
            8 => move.to_frame.kind = .block,
            9 => move.reason = .lowerer_scope_relocation,
            10 => transfer.target_owner.node = transfer.source_owner.node,
            11 => {
                transfer.target_owner = peer_move.static_block.?.target_owner;
                transfer.parameters = peer_move.static_block.?.parameters;
                transfer.output_body = peer_move.static_block.?.output_body;
                transfer.birth_epoch = peer_move.static_block.?.birth_epoch;
                move.to = peer_move.to;
                move.to_frame = peer_move.to_frame;
                wrong.scope = peer_move.to;
            },
            else => unreachable,
        }
        wrong.source_external = changed;
        try data.node_scope_provenance.put(a, chosen.node, wrong);
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    }
    var replay = chosen.entry;
    var replay_origin = original;
    const replay_moves = try a.alloc(ScopeMove, original.scope_moves.len + 1);
    @memcpy(replay_moves[0..original.scope_moves.len], original.scope_moves);
    replay_moves[original.scope_moves.len] = original.scope_moves[chosen.move_index];
    replay_origin.scope_moves = replay_moves;
    replay.source_external = replay_origin;
    try data.node_scope_provenance.put(a, chosen.node, replay);
    try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
    // A valid first handoff cannot authorize a later lexical move into a
    // different actual wrapper, even with its matching frame snapshot.
    var history_index = try @import("scope_frame_history.zig").validateAndIndex(a, transformer.ast, data.scopes, &data.scope_owner_map, &data.scope_history, null);
    try std.testing.expect(history_index.valid);
    var foreign = chosen.entry;
    foreign.source_external = try moved(a, original, chosen.node, chosen.entry.source_node, chosen.entry.scope, peer_move.to, data.scopes, @intCast(data.scope_history.events.len));
    foreign.scope = peer_move.to;
    try data.node_scope_provenance.put(a, chosen.node, foreign);
    try std.testing.expect(!validate(transformer.ast, parser_node_count, data.symbol_ids, data.scopes, &analyzer.unresolved_reference_nodes, &data.node_scope_provenance, &history_index));
    try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
    // A witness and a function body edge changed together still must not
    // turn the other actual wrapper's body into this producer's output.
    const selected_move = original.scope_moves[chosen.move_index];
    const target = transformer.ast.getNode(selected_move.static_block.?.target_owner.node);
    const body_slot = target.data.extra + ast.FunctionExtra.body;
    const actual_body = transformer.ast.extra_data.items[body_slot];
    const Saved = struct { node: ast.NodeIndex, entry: @import("node_scope_provenance.zig").Entry };
    var saved: std.ArrayList(Saved) = .empty;
    var all_entries = data.node_scope_provenance.iterator();
    while (all_entries.next()) |entry| {
        const before = entry.value_ptr.*;
        const old_origin = before.source_external orelse continue;
        var changed_origin = old_origin;
        const changed_moves = try a.dupe(ScopeMove, old_origin.scope_moves);
        var changed_any = false;
        for (changed_moves) |*move| {
            if (move.static_block) |*transfer| {
                if (transfer.target_owner.node != selected_move.static_block.?.target_owner.node) continue;
                transfer.output_body = peer_move.static_block.?.output_body;
                changed_any = true;
            }
        }
        if (!changed_any) continue;
        try saved.append(a, .{ .node = entry.key_ptr.*, .entry = before });
        changed_origin.scope_moves = changed_moves;
        entry.value_ptr.source_external = changed_origin;
    }
    try std.testing.expect(saved.items.len > 1);
    transformer.ast.extra_data.items[body_slot] = @backingInt(peer_move.static_block.?.output_body);
    try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    transformer.ast.extra_data.items[body_slot] = actual_body;
    for (saved.items) |before| try data.node_scope_provenance.put(a, before.node, before.entry);
    var wire: std.ArrayList(u8) = .empty;
    try @import("../bundler/semantic_codec.zig").serialize(&data, &wire, a);
    var restored = try @import("../bundler/semantic_codec.zig").deserialize(wire.items, a);
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &restored, &analyzer.unresolved_reference_nodes, &transformer));
    const Trial = struct {
        fn build(alloc: std.mem.Allocator, input: []const u8) !@import("../transpile.zig").TranspileResult {
            return @import("../transpile.zig").transpile(alloc, input, "input.js", .{ .minify_identifiers = true, .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es2015) });
        }
        fn runtime(code: []const u8) !void {
            const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
            try std.testing.expect(result.term == .exited and result.term.exited == 0);
            try std.testing.expectEqualStrings("", result.stderr);
            try std.testing.expectEqualStrings("1 1\n", result.stdout);
        }
    };
    try Trial.runtime(source);
    var baseline_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var baseline = try Trial.build(baseline_alloc.allocator(), source);
    try Trial.runtime(baseline.code);
    baseline.deinit(baseline_alloc.allocator());
    const windows = baseline_alloc.alloc_index;
    try std.testing.expectEqual(baseline_alloc.allocated_bytes, baseline_alloc.freed_bytes);
    var recovered: usize = 0;
    var oom_errors: usize = 0;
    var mapped_errors: usize = 0;
    for (0..windows) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        if (Trial.build(failing.allocator(), source)) |built| {
            var result = built;
            defer result.deinit(failing.allocator());
            // Existing best-effort recovery is successful only with the same
            // actual Node result; it is not a rollback/error observation.
            try Trial.runtime(result.code);
            recovered += 1;
        } else |err| switch (err) {
            error.OutOfMemory => oom_errors += 1,
            // The public API already maps parser/analyzer/transform errors.
            // Keep that contract; these are rejected pure calls, not Module
            // transaction rollback or successful semantic publication.
            error.ParseError, error.SemanticError, error.TransformError => mapped_errors += 1,
            else => return err,
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect(windows > 0 and oom_errors + mapped_errors > 0);
    std.debug.print("STATIC_EXTERNAL_BOUNDARY poison14 codec1 windows={d} recovered={d} oom_errors={d} mapped_errors={d}\n", .{ windows, recovered, oom_errors, mapped_errors });
}

pub fn transferredGenerator(a: @import("std").mem.Allocator, origin: Origin, node: ast.NodeIndex, source_node: ast.NodeIndex, from: scope.ScopeId, to: scope.ScopeId, scopes: []const scope.Scope, frame_epoch: u32, transfer: @import("generator_environment_transfer.zig").Transfer) !Origin {
    const next = try moved(a, origin, node, source_node, from, to, scopes, frame_epoch);
    if (from == to) return next;
    const moves = @constCast(next.scope_moves);
    moves[moves.len - 1].reason = .generator_environment_transfer;
    moves[moves.len - 1].generator = transfer;
    return next;
}

fn validClassHeritage(tree: *const ast.Ast, index: *const @import("scope_frame_history.zig").Index, origin: Origin, move: ScopeMove, transfer: ClassHeritageTransfer, parser_count: u32) bool {
    const std = @import("std");
    if (transfer.class_scope != move.from or transfer.evaluation_scope != move.to or origin.execution_scope != transfer.class_scope or
        transfer.capture_epoch > move.frame_epoch or move.source_node != transfer.heritage or transfer.heritage.isNone() or
        @backingInt(transfer.heritage) >= parser_count or transfer.owner.node.isNone() or @backingInt(transfer.owner.node) >= parser_count or
        origin.tag != .identifier_reference or !origin.flags.read or origin.flags.write or origin.flags.type_context or origin.flags.value_as_type or
        (transfer.owner.tag != .class_declaration and transfer.owner.tag != .class_expression)) return false;
    const before = index.frameAt(transfer.class_scope, transfer.capture_epoch) orelse return false;
    if (before.kind != .class_body or before.parent != transfer.evaluation_scope) return false;
    var matches: usize = 0;
    for (index.history.source_owners) |binding| if (binding.scope == transfer.class_scope and std.meta.eql(binding.owner, transfer.owner) and binding.edges.heritage == transfer.heritage) {
        matches += 1;
    };
    if (matches != 1 or !tree.hasExtra(transfer.owner.words[0], ast.ClassExtra.super) or tree.readExtraNode(transfer.owner.words[0], ast.ClassExtra.super) != transfer.heritage) return false;
    const heritage = tree.getNode(transfer.heritage);
    return heritage.tag == .identifier_reference and std.meta.eql(heritage.data.string_ref, origin.name) and std.meta.eql(heritage.span, origin.span);
}

pub fn classHeritage(a: @import("std").mem.Allocator, origin: Origin, transfer: ClassHeritageTransfer, node: ast.NodeIndex, source_node: ast.NodeIndex) !Origin {
    if (origin.scope_moves.len == 0) return error.InvalidScope;
    const previous = origin.scope_moves[origin.scope_moves.len - 1];
    if (previous.node != node or previous.source_node != source_node or source_node != transfer.heritage or previous.from != transfer.class_scope or previous.to != transfer.evaluation_scope or previous.reason != .lowerer_scope_relocation) return error.InvalidScope;
    const moves = try a.dupe(ScopeMove, origin.scope_moves);
    moves[moves.len - 1].reason = .class_heritage_evaluation;
    moves[moves.len - 1].class_heritage = transfer;
    var next = origin;
    next.scope_moves = moves;
    return next;
}

test "generator and heritage source witnesses preserve immutable edges and reject paired body epochs" {
    const std = @import("std");
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const source = "class A extends Promise{}class B extends Promise{}async function first(){const One=class extends(await pendingCtor){};return One}async function second(){const Two=class extends(await pendingCtor){};return Two}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    const parser_node_count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es5);
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var transformer = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIdsOwned(analyzer.ast, analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.helper_scope_map = analyzer.helper_scope_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.scope_history = analyzer.scope_history;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.record_explicit_global_references = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var data: Data = .{
        .symbols = edited.symbols,
        .scopes = edited.scopes,
        .scope_maps = edited.scope_maps,
        .scope_owner_map = edited.scope_owner_map,
        .symbol_ids = edited.symbol_ids,
        .references = edited.references,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
        .helper_scope_map = edited.helper_scope_map,
        .node_scope_provenance = edited.node_scope_provenance,
        .scope_history = edited.scope_history,
        .source_owned_retirements = edited.source_owned_retirements,
    };
    const Check = struct {
        fn run(alloc: std.mem.Allocator, tree: *const ast.Ast, output_root: ast.NodeIndex, parser_count: u32, sem: *const Data, unresolved: *const std.AutoHashMapUnmanaged(u32, void), producer: *const Transformer) !bool {
            var report = try @import("../transformer/symbol_coverage.zig").checkOutputNormalFormQuiet(alloc, tree, output_root, parser_count, sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, producer.helper_ref_nodes.items, &sem.helper_scope_map, unresolved, &producer.explicit_global_reference_nodes, &producer.reference_origin_map, .{ .pre_transform_scope_count = sem.scope_history.source_scopes.len }, &sem.source_owned_retirements, .{
                .node_scope_provenance = &sem.node_scope_provenance,
                .scope_history = &sem.scope_history,
                .runtime_helper_symbols = &producer.runtime_helper_symbol_ids,
                .class_self_symbols = &producer.class_self_symbol_map,
            });
            defer report.deinit(alloc);
            return report.hasCompleteOutputIdentityBeforeNames();
        }
    };
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    const Entry = @import("node_scope_provenance.zig").Entry;
    const Selected = struct { node: ast.NodeIndex, entry: Entry, index: usize };
    var selected: ?Selected = null;
    var other: ?Selected = null;
    var heritage: ?Selected = null;
    var other_heritage: ?Selected = null;
    var entries = data.node_scope_provenance.iterator();
    while (entries.next()) |entry| {
        const external = entry.value_ptr.source_external orelse continue;
        for (external.scope_moves, 0..) |move, i| {
            if (move.generator) |transfer| {
                if (selected == null) selected = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .index = i } else if (transfer.source.owner.node != selected.?.entry.source_external.?.scope_moves[selected.?.index].generator.?.source.owner.node) other = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .index = i };
            }
            if (move.class_heritage) |transfer| {
                if (heritage == null) heritage = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .index = i } else if (transfer.owner.node != heritage.?.entry.source_external.?.scope_moves[heritage.?.index].class_heritage.?.owner.node) other_heritage = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .index = i };
            }
        }
    }
    const chosen = selected orelse return error.TestExpectedEqual;
    const peer = other orelse return error.TestExpectedEqual;
    const before = chosen.entry.source_external.?;
    const original = before.scope_moves[chosen.index].generator.?;
    const foreign = peer.entry.source_external.?.scope_moves[peer.index].generator.?;
    for (0..15) |which| {
        var changed = original;
        switch (which) {
            0 => changed.source.owner = foreign.source.owner,
            1 => changed.source.scope = foreign.source.scope,
            2 => changed.source.parameters = foreign.source.parameters,
            3 => changed.source.body = foreign.source.body,
            4 => changed.callback = foreign.callback,
            5 => changed.callback_scope = foreign.callback_scope,
            6 => changed.parameters = foreign.parameters,
            7 => changed.body = foreign.body,
            8 => changed.state_parameter = foreign.state_parameter,
            9 => changed.birth_epoch = foreign.birth_epoch,
            10 => changed = foreign,
            11 => changed.heritage = null,
            12 => changed.heritage = foreign.heritage,
            13 => changed.heritage.?.read = foreign.heritage.?.read,
            14 => changed.heritage.?.await_node = foreign.heritage.?.await_node,
            else => unreachable,
        }
        const moves = try a.dupe(ScopeMove, before.scope_moves);
        moves[chosen.index].generator = changed;
        var changed_origin = before;
        changed_origin.scope_moves = moves;
        var entry = chosen.entry;
        entry.source_external = changed_origin;
        try data.node_scope_provenance.put(a, chosen.node, entry);
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
    }
    // Reusing the same source-function receipt for this leaf is not another
    // producer operation. Exercise the actual SourceExternal consumer as well
    // as the full output graph check.
    {
        const moves = try a.alloc(ScopeMove, before.scope_moves.len + 1);
        @memcpy(moves[0..before.scope_moves.len], before.scope_moves);
        var replay = before.scope_moves[chosen.index];
        replay.from = replay.to;
        replay.to = original.callback_scope;
        var indexed = try @import("scope_frame_history.zig").validateAndIndex(a, transformer.ast, data.scopes, &data.scope_owner_map, &data.scope_history, null);
        try std.testing.expect(indexed.valid);
        replay.from_frame = indexed.frameAt(replay.from, replay.frame_epoch).?;
        replay.to_frame = indexed.frameAt(replay.to, replay.frame_epoch).?;
        moves[moves.len - 1] = replay;
        var origin = before;
        origin.scope_moves = moves;
        var entry = chosen.entry;
        entry.scope = replay.to;
        entry.source_external = origin;
        try data.node_scope_provenance.put(a, chosen.node, entry);
        try std.testing.expect(!validate(transformer.ast, parser_node_count, data.symbol_ids, data.scopes, &analyzer.unresolved_reference_nodes, &data.node_scope_provenance, &indexed));
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
    }
    // The output graph is unchanged in these paired source-only mutations.
    // Current old extras plus a forged receipt must not replace epoch0 edges.
    inline for (.{ ast.FunctionExtra.params, ast.FunctionExtra.body }) |slot| {
        const old = transformer.ast.extra_data.items[original.source.owner.words[0] + slot];
        const replacement = if (slot == ast.FunctionExtra.params) foreign.source.parameters else foreign.source.body;
        transformer.ast.extra_data.items[original.source.owner.words[0] + slot] = @backingInt(replacement);
        var changed = original;
        if (slot == ast.FunctionExtra.params) changed.source.parameters = replacement else changed.source.body = replacement;
        const moves = try a.dupe(ScopeMove, before.scope_moves);
        moves[chosen.index].generator = changed;
        var changed_origin = before;
        changed_origin.scope_moves = moves;
        var entry = chosen.entry;
        entry.source_external = changed_origin;
        try data.node_scope_provenance.put(a, chosen.node, entry);
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        transformer.ast.extra_data.items[original.source.owner.words[0] + slot] = old;
        try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
    }
    const direct = heritage orelse return error.TestExpectedEqual;
    const direct_other = other_heritage orelse return error.TestExpectedEqual;
    const old_direct = direct.entry.source_external.?;
    const direct_move = old_direct.scope_moves[direct.index];
    const known = direct_move.class_heritage.?;
    const other_known = direct_other.entry.source_external.?.scope_moves[direct_other.index].class_heritage.?;
    for (0..6) |which| {
        var changed = known;
        switch (which) {
            0 => changed.owner = other_known.owner,
            1 => changed.class_scope = other_known.class_scope,
            2 => changed.heritage = other_known.heritage,
            3 => changed.evaluation_scope = other_known.class_scope,
            4 => changed.capture_epoch = direct_move.frame_epoch + 1,
            5 => changed = other_known,
            else => unreachable,
        }
        const moves = try a.dupe(ScopeMove, old_direct.scope_moves);
        moves[direct.index].class_heritage = changed;
        var origin = old_direct;
        origin.scope_moves = moves;
        var entry = direct.entry;
        entry.source_external = origin;
        try data.node_scope_provenance.put(a, direct.node, entry);
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        try data.node_scope_provenance.put(a, direct.node, direct.entry);
    }
    // A paired current class-super and receipt mutation still cannot replace
    // the original source-owner's immutable heritage edge.
    const super_slot = known.owner.words[0] + ast.ClassExtra.super;
    const old_super = transformer.ast.extra_data.items[super_slot];
    transformer.ast.extra_data.items[super_slot] = @backingInt(other_known.heritage);
    var paired = known;
    paired.heritage = other_known.heritage;
    var paired_move = direct_move;
    paired_move.source_node = other_known.heritage;
    var paired_origin = old_direct;
    paired_origin.name = transformer.ast.getNode(other_known.heritage).data.string_ref;
    paired_origin.span = transformer.ast.getNode(other_known.heritage).span;
    var frame_index = try @import("scope_frame_history.zig").validateAndIndex(a, transformer.ast, data.scopes, &data.scope_owner_map, &data.scope_history, null);
    try std.testing.expect(frame_index.valid);
    try std.testing.expect(!validClassHeritage(transformer.ast, &frame_index, paired_origin, paired_move, paired, parser_node_count));
    transformer.ast.extra_data.items[super_slot] = old_super;
    var wire: std.ArrayList(u8) = .empty;
    try @import("../bundler/semantic_codec.zig").serialize(&data, &wire, a);
    var restored = try @import("../bundler/semantic_codec.zig").deserialize(wire.items, a);
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &restored, &analyzer.unresolved_reference_nodes, &transformer));
    var repeated = try restored.beginEdit(a, transformer.ast);
    restored.applyEdit(try repeated.finish());
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &restored, &analyzer.unresolved_reference_nodes, &transformer));
}

test "static initializer factory authenticates source carriers and rejects paired owner substitutions" {
    const std = @import("std");
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const source = "class First{static value=(console.log(1),7)}class Second{static value=(console.log(2),8)}console.log(First.value,Second.value);";
    for ([_]@import("../transformer/compat.zig").ESTarget{ .es2021, .es5 }) |target| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        const parser_node_count: u32 = @intCast(parser.ast.nodes.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(target);
        analyzer.collect_unresolved_reference_nodes = true;
        analyzer.enable_source_external_origins = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const initial_tree = try ast.Ast.cloneForTransformer(&parser.ast, a);
        const initial_scopes = try a.dupe(@import("scope.zig").Scope, analyzer.scopes.items);
        const initial_owners = try analyzer.scope_owner_map.clone(a);
        var transformer = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(target) });
        try transformer.initSymbolIdsOwned(analyzer.ast, analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.helper_scope_map = analyzer.helper_scope_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.scope_history = analyzer.scope_history;
        transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = true;
        transformer.record_explicit_global_references = true;
        const root = try transformer.transform();
        const edited = (try transformer.finishSemanticEdit()).?;
        var data: Data = .{
            .symbols = edited.symbols,
            .scopes = edited.scopes,
            .scope_maps = edited.scope_maps,
            .scope_owner_map = edited.scope_owner_map,
            .symbol_ids = edited.symbol_ids,
            .references = edited.references,
            .exported_names = analyzer.exported_names,
            .unresolved_references = analyzer.unresolved_references,
            .helper_scope_map = edited.helper_scope_map,
            .node_scope_provenance = edited.node_scope_provenance,
            .scope_history = edited.scope_history,
            .source_owned_retirements = edited.source_owned_retirements,
        };
        const Check = struct {
            fn run(alloc: std.mem.Allocator, tree: *const ast.Ast, output_root: ast.NodeIndex, parser_count: u32, sem: *const Data, unresolved: *const std.AutoHashMapUnmanaged(u32, void), producer: *const Transformer) !bool {
                var report = try @import("../transformer/symbol_coverage.zig").checkOutputNormalFormQuiet(alloc, tree, output_root, parser_count, sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, producer.helper_ref_nodes.items, &sem.helper_scope_map, unresolved, &producer.explicit_global_reference_nodes, &producer.reference_origin_map, .{ .pre_transform_scope_count = sem.scope_history.source_scopes.len }, &sem.source_owned_retirements, .{
                    .node_scope_provenance = &sem.node_scope_provenance,
                    .scope_history = &sem.scope_history,
                    .runtime_helper_symbols = &producer.runtime_helper_symbol_ids,
                    .class_self_symbols = &producer.class_self_symbol_map,
                });
                defer report.deinit(alloc);
                return report.hasCompleteOutputIdentityBeforeNames();
            }
        };
        try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        const Selected = struct { node: ast.NodeIndex, entry: @import("node_scope_provenance.zig").Entry, move_index: usize };
        var selected: ?Selected = null;
        var other: ?Selected = null;
        var entries = data.node_scope_provenance.iterator();
        while (entries.next()) |entry| {
            const origin = entry.value_ptr.source_external orelse continue;
            for (origin.scope_moves, 0..) |move, index| {
                const transfer = move.class_initializer orelse continue;
                if (selected == null) selected = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .move_index = index } else if (transfer.source_index != selected.?.entry.source_external.?.scope_moves[selected.?.move_index].class_initializer.?.source_index)
                    other = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .move_index = index };
            }
        }
        const chosen = selected orelse return error.TestUnexpectedResult;
        const peer = other orelse return error.TestUnexpectedResult;
        const original = chosen.entry.source_external.?;
        const peer_move = peer.entry.source_external.?.scope_moves[peer.move_index];
        const moves = try a.dupe(ScopeMove, original.scope_moves);
        for (0..9) |poison| {
            @memcpy(moves, original.scope_moves);
            var wrong = chosen.entry;
            var changed = original;
            changed.scope_moves = moves;
            const move = &moves[chosen.move_index];
            const transfer = &move.class_initializer.?;
            switch (poison) {
                0 => transfer.source_index = peer_move.class_initializer.?.source_index,
                1 => transfer.target_owner = peer_move.class_initializer.?.target_owner,
                2 => transfer.parameters = peer_move.class_initializer.?.parameters,
                3 => transfer.body = peer_move.class_initializer.?.body,
                4 => transfer.owner_epoch = 0,
                5 => transfer.owner_epoch = peer_move.class_initializer.?.owner_epoch,
                6 => {
                    move.reason = .lowerer_scope_relocation;
                    move.class_initializer = null;
                },
                7 => move.from_frame.is_strict = false,
                8 => {
                    transfer.* = peer_move.class_initializer.?;
                    move.to = peer_move.to;
                    move.to_frame = peer_move.to_frame;
                    wrong.scope = peer_move.to;
                },
                else => unreachable,
            }
            wrong.source_external = changed;
            try data.node_scope_provenance.put(a, chosen.node, wrong);
            try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        }
        try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
        var replay = chosen.entry;
        var replay_origin = original;
        const replay_moves = try a.alloc(ScopeMove, original.scope_moves.len + 1);
        @memcpy(replay_moves[0..original.scope_moves.len], original.scope_moves);
        replay_moves[original.scope_moves.len] = original.scope_moves[chosen.move_index];
        replay_origin.scope_moves = replay_moves;
        replay.source_external = replay_origin;
        try data.node_scope_provenance.put(a, chosen.node, replay);
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
        const Codec = @import("../bundler/semantic_codec.zig");
        var bytes: std.ArrayList(u8) = .empty;
        try Codec.serialize(&data, &bytes, a);
        var decoded = try Codec.deserialize(bytes.items, a);
        try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &decoded, &analyzer.unresolved_reference_nodes, &transformer));
        const H = @import("scope_frame_history.zig");
        var copied = try H.Recorder.fromHistory(a, decoded.scope_history);
        const before = decoded.scope_history.source_initializers;
        decoded.scope_history = try copied.finish(a);
        try std.testing.expect(decoded.scope_history.source_initializers.ptr != before.ptr);
        try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &decoded, &analyzer.unresolved_reference_nodes, &transformer));
        const Oom = struct {
            fn run(allocator: std.mem.Allocator, history: H.History) !void {
                var recorder = try H.Recorder.fromHistory(allocator, history);
                defer recorder.deinit(allocator);
            }
        };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Oom.run, .{data.scope_history});
        const CaptureOom = struct {
            fn run(allocator: std.mem.Allocator, tree: *const ast.Ast, scopes: []const @import("scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) !void {
                var recorder = try H.Recorder.init(allocator, tree, scopes, owners);
                defer recorder.deinit(allocator);
            }
        };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, CaptureOom.run, .{ &initial_tree, initial_scopes, &initial_owners });
        const output = try @import("../transpile.zig").transpile(a, source, "input.js", .{ .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(target), .minify_identifiers = true, .minify_syntax = true });
        const node = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
        try std.testing.expect(node.term == .exited and node.term.exited == 0);
        try std.testing.expectEqualStrings("1\n2\n7 8\n", node.stdout);
    }
}

test "generator loop handoffs authenticate actual source bodies births and computed await leaves" {
    const std = @import("std");
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const source = "async function first(){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve(\"read\"+i)]=()=>this})}return all}async function second(){const all=[];while(all.length<2){class C{[await Promise.resolve(\"other\"+all.length)]=()=>this}all.push(C)}return all}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    const parser_node_count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const initial_tree = try ast.Ast.cloneForTransformer(&parser.ast, a);
    const initial_scopes = try a.dupe(@import("scope.zig").Scope, analyzer.scopes.items);
    const initial_owners = try analyzer.scope_owner_map.clone(a);
    var transformer = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80), .use_define_for_class_fields = true });
    try transformer.initSymbolIdsOwned(analyzer.ast, analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.helper_scope_map = analyzer.helper_scope_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.scope_history = analyzer.scope_history;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.record_explicit_global_references = true;
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var data: Data = .{
        .symbols = edited.symbols,
        .scopes = edited.scopes,
        .scope_maps = edited.scope_maps,
        .scope_owner_map = edited.scope_owner_map,
        .symbol_ids = edited.symbol_ids,
        .references = edited.references,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
        .helper_scope_map = edited.helper_scope_map,
        .node_scope_provenance = edited.node_scope_provenance,
        .scope_history = edited.scope_history,
        .source_owned_retirements = edited.source_owned_retirements,
    };
    const Check = struct {
        fn run(alloc: std.mem.Allocator, tree: *const ast.Ast, output_root: ast.NodeIndex, parser_count: u32, sem: *const Data, unresolved: *const std.AutoHashMapUnmanaged(u32, void), producer: *const Transformer) !bool {
            var report = try @import("../transformer/symbol_coverage.zig").checkOutputNormalFormQuiet(alloc, tree, output_root, parser_count, sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, producer.helper_ref_nodes.items, &sem.helper_scope_map, unresolved, &producer.explicit_global_reference_nodes, &producer.reference_origin_map, .{ .pre_transform_scope_count = sem.scope_history.source_scopes.len }, &sem.source_owned_retirements, .{
                .node_scope_provenance = &sem.node_scope_provenance,
                .scope_history = &sem.scope_history,
                .runtime_helper_symbols = &producer.runtime_helper_symbol_ids,
                .class_self_symbols = &producer.class_self_symbol_map,
            });
            defer report.deinit(alloc);
            return report.hasCompleteOutputIdentityBeforeNames();
        }
    };
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    const Entry = @import("node_scope_provenance.zig").Entry;
    const Selected = struct { node: ast.NodeIndex, entry: Entry, index: usize };
    var selected: ?Selected = null;
    var peer: ?Selected = null;
    var entries = data.node_scope_provenance.iterator();
    while (entries.next()) |entry| {
        const external = entry.value_ptr.source_external orelse continue;
        for (external.scope_moves, 0..) |move, i| {
            const transfer = move.generator orelse continue;
            if (transfer.source.extracted_loop == null or transfer.computed_await_source == null) continue;
            if (selected == null) selected = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .index = i } else if (transfer.source.owner.node != selected.?.entry.source_external.?.scope_moves[selected.?.index].generator.?.source.owner.node)
                peer = .{ .node = entry.key_ptr.*, .entry = entry.value_ptr.*, .index = i };
        }
    }
    const chosen = selected orelse return error.TestExpectedEqual;
    const other = peer orelse return error.TestExpectedEqual;
    const original = chosen.entry.source_external.?;
    const foreign = other.entry.source_external.?.scope_moves[other.index].generator.?;
    for (0..13) |poison| {
        var changed = chosen.entry;
        var origin = original;
        const moves = try a.dupe(ScopeMove, origin.scope_moves);
        const transfer = &moves[chosen.index].generator.?;
        switch (poison) {
            0 => transfer.source.extracted_loop.?.loop_owner = foreign.source.extracted_loop.?.loop_owner,
            1 => transfer.source.extracted_loop.?.loop_scope = foreign.source.extracted_loop.?.loop_scope,
            2 => transfer.source.extracted_loop.?.loop_body = foreign.source.extracted_loop.?.loop_body,
            3 => transfer.source.extracted_loop.?.function_owner = foreign.source.extracted_loop.?.function_owner,
            4 => transfer.source.extracted_loop.?.function_scope = foreign.source.extracted_loop.?.function_scope,
            5 => transfer.source.extracted_loop.?.parameters = foreign.source.extracted_loop.?.parameters,
            6 => transfer.source.extracted_loop.?.body = foreign.source.extracted_loop.?.body,
            7 => transfer.source.extracted_loop.?.birth_epoch = 0,
            8 => transfer.source.extracted_loop = foreign.source.extracted_loop,
            9 => transfer.computed_await_source = foreign.computed_await_source,
            10 => transfer.computed_await_source = null,
            11 => transfer.* = foreign,
            12 => {
                transfer.source.extracted_loop.?.function_owner = foreign.source.extracted_loop.?.function_owner;
                transfer.source.extracted_loop.?.parameters = foreign.source.extracted_loop.?.parameters;
                transfer.source.extracted_loop.?.body = foreign.source.extracted_loop.?.body;
                transfer.source.extracted_loop.?.birth_epoch = foreign.source.extracted_loop.?.birth_epoch;
            },
            else => unreachable,
        }
        origin.scope_moves = moves;
        changed.source_external = origin;
        try data.node_scope_provenance.put(a, chosen.node, changed);
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_node_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    }
    try data.node_scope_provenance.put(a, chosen.node, chosen.entry);
    const H = @import("scope_frame_history.zig");
    const Codec = @import("../bundler/semantic_codec.zig");
    var wire: std.ArrayList(u8) = .empty;
    try Codec.serialize(&data, &wire, a);
    var decoded = try Codec.deserialize(wire.items, a);
    try std.testing.expect(decoded.scope_history.source_computed_awaits.len > 0);
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &decoded, &analyzer.unresolved_reference_nodes, &transformer));
    const old_backing = decoded.scope_history.source_computed_awaits.ptr;
    var recorder = try H.Recorder.fromHistory(a, decoded.scope_history);
    decoded.scope_history = try recorder.finish(a);
    try std.testing.expect(decoded.scope_history.source_computed_awaits.ptr != old_backing);
    var edit = try decoded.beginEdit(a, transformer.ast);
    decoded.applyEdit(try edit.finish());
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_node_count, &decoded, &analyzer.unresolved_reference_nodes, &transformer));
    const Oom = struct {
        fn run(allocator: std.mem.Allocator, history: H.History) !void {
            var owned = try H.Recorder.fromHistory(allocator, history);
            defer owned.deinit(allocator);
        }
        fn capture(allocator: std.mem.Allocator, tree: *const ast.Ast, scopes: []const @import("scope.zig").Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) !void {
            var owned = try H.Recorder.init(allocator, tree, scopes, owners);
            defer owned.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Oom.run, .{data.scope_history});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Oom.capture, .{ &initial_tree, initial_scopes, &initial_owners });
}

test "JSX component conversion retains the exact initial lookup and rejects forged headers" {
    const std = @import("std");
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const H = @import("scope_frame_history.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "const first=<Comp/>;const second=<Other.Member/>;const intrinsic=<span/>;");
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".tsx");
    _ = try parser.parse();
    const parser_count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_source_external_origins = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var t = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .jsx_transform = true, .jsx_runtime = .classic });
    try t.initSymbolIdsOwned(analyzer.ast, analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.helper_scope_map = analyzer.helper_scope_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.scope_history = analyzer.scope_history;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    t.record_explicit_global_references = true;
    _ = try t.transform();
    const result = (try t.finishSemanticEdit()).?;
    const indexed = try H.validateAndIndex(a, t.ast, result.scopes, &result.scope_owner_map, &result.scope_history, null);
    try std.testing.expect(indexed.valid);
    try std.testing.expect(validate(t.ast, parser_count, result.symbol_ids, result.scopes, &analyzer.unresolved_reference_nodes, &result.node_scope_provenance, &indexed));
    var entries = result.node_scope_provenance.iterator();
    var count: usize = 0;
    while (entries.next()) |entry| {
        const original = entry.value_ptr.*;
        const origin = original.source_external orelse continue;
        const conversion = origin.jsx_reference orelse continue;
        try std.testing.expectEqual(ast.Node.Tag.jsx_identifier, conversion.tag);
        try std.testing.expectEqual(ast.Node.Tag.identifier_reference, t.ast.getNode(entry.key_ptr.*).tag);
        for (0..7) |poison| {
            var bad = original;
            switch (poison) {
                0 => bad.source_external.?.jsx_reference = null,
                1 => bad.source_external.?.jsx_reference.?.node = .none,
                2 => bad.source_external.?.jsx_reference.?.tag = .identifier_reference,
                3 => bad.source_external.?.jsx_reference.?.span.start +%= 1,
                4 => bad.source_external.?.jsx_reference.?.words[0] ^= 1,
                5 => bad.source_external.?.flags.write = true,
                6 => bad.source_external.?.tag = .identifier_reference,
                else => unreachable,
            }
            entry.value_ptr.* = bad;
            try std.testing.expect(!validate(t.ast, parser_count, result.symbol_ids, result.scopes, &analyzer.unresolved_reference_nodes, &result.node_scope_provenance, &indexed));
            entry.value_ptr.* = original;
        }
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const data: Data = .{ .symbols = result.symbols, .scopes = result.scopes, .scope_maps = result.scope_maps, .scope_owner_map = result.scope_owner_map, .symbol_ids = result.symbol_ids, .references = result.references, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .helper_scope_map = result.helper_scope_map, .node_scope_provenance = result.node_scope_provenance, .scope_history = result.scope_history, .source_owned_retirements = result.source_owned_retirements };
    var wire: std.ArrayList(u8) = .empty;
    const Codec = @import("../bundler/semantic_codec.zig");
    try Codec.serialize(&data, &wire, a);
    const decoded = try Codec.deserialize(wire.items, a);
    const decoded_index = try H.validateAndIndex(a, t.ast, decoded.scopes, &decoded.scope_owner_map, &decoded.scope_history, null);
    try std.testing.expect(decoded_index.valid);
    try std.testing.expect(validate(t.ast, parser_count, decoded.symbol_ids, decoded.scopes, &analyzer.unresolved_reference_nodes, &decoded.node_scope_provenance, &decoded_index));
}
