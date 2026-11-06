//! A class-key producer moves exact initial read expressions to its enclosing
//! evaluation scope. This permission does not cover class self/TDZ or writes.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const H = @import("scope_frame_history.zig");
const Scope = @import("scope.zig");
pub const Transfer = struct { source_index: u32, evaluation_scope: Scope.ScopeId, capture_epoch: u32 };

pub fn validates(tree: *const Ast.Ast, history: *const H.Index, parser_count: u32, origin: anytype, move: anytype, transfer: Transfer) bool {
    if (!history.valid or transfer.source_index >= history.history.source_class_keys.len or transfer.capture_epoch != move.frame_epoch or
        move.from != origin.source_scope or origin.execution_scope != origin.source_scope or transfer.evaluation_scope != move.to or
        !origin.flags.read or origin.flags.write or origin.flags.declare or origin.flags.type_context or origin.flags.value_as_type or
        origin.source_frame.kind != .class_body or !origin.source_frame.is_strict or origin.source_frame.blocksMangling()) return false;
    const source = history.history.source_class_keys[transfer.source_index];
    if (source.scope != move.from or source.class_owner.node.isNone() or @backingInt(source.class_owner.node) >= parser_count or
        source.leaf.node != move.source_node or source.leaf.tag != origin.tag or !std.meta.eql(source.leaf.span, origin.span) or
        source.leaf.words[0] != origin.name.start or source.leaf.words[1] != origin.name.end or
        source.key.tag != .computed_property_key or source.key.node.isNone() or @backingInt(source.key.node) >= parser_count) return false;
    const initial = history.frameAt(source.scope, 0) orelse return false;
    if (initial.kind != .class_body or initial.blocksMangling() or !initial.is_strict) return false;
    if (initial.parent != move.to and !validatesIife(tree, history, source.scope, initial.parent, move.to, transfer.capture_epoch)) return false;
    // The immutable source class/member/key relation is independent of the
    // lowered temporary. Never reconstruct a declaration by its spelling.
    if (source.member.words[0] >= tree.extra_data.items.len or tree.extra_data.items[source.member.words[0]] != @backingInt(source.key.node)) return false;
    return transfer.source_index < history.class_key_read_membership.len and history.class_key_read_membership[transfer.source_index];
}

// This branch is solely the class lowerer's generated evaluation environment.
// History authenticates the exact reparent and owner publication; the normal
// form gate independently requires that current owner to be reachable.
fn validatesIife(tree: *const Ast.Ast, history: *const H.Index, source: Scope.ScopeId, parent: Scope.ScopeId, target: Scope.ScopeId, epoch: u32) bool {
    if (target.isNone() or target.toIndex() < history.history.source_scopes.len or epoch == 0 or epoch > history.history.events.len) return false;
    const frame = history.frameAt(target, epoch) orelse return false;
    const current = history.frameAt(target, @intCast(history.history.events.len)) orelse return false;
    const class_frame = history.frameAt(source, epoch) orelse return false;
    const current_class = history.frameAt(source, @intCast(history.history.events.len)) orelse return false;
    if (frame.kind != .function or frame.parent != parent or frame.blocksMangling() or
        (!@import("source_external_origin.zig").sameFrame(frame, current) and !parameterBodyReparent(tree, history, target, epoch, frame, current)) or class_frame.parent != target or current_class.parent != target) return false;
    var reparented = false;
    var published: ?H.Event = null;
    var latest: ?H.Event = null;
    for (history.history.events, 0..) |event, index| {
        if (index < epoch and event.kind == .frame and event.scope == source and event.trigger_scope == source and event.trigger_parent == target) {
            const before = event.before orelse return false;
            if (before.parent == parent and event.after.parent == target) reparented = true;
        }
        if (event.scope == target and (event.kind == .owner or event.kind == .birth)) {
            if (index < epoch) published = event;
            latest = event;
        }
    }
    if (!reparented) return false;
    const publication = history.history.events[epoch - 1];
    if (publication.scope != target or publication.kind != .owner or publication.owner_after == null) return false;
    const at_capture = published orelse return false;
    const final = latest orelse return false;
    // Exact edge payloads are required even if the function's extra index did
    // not change. Owner-copy events may publish the current physical carrier.
    inline for (.{ at_capture, final }) |event| {
        const owner = event.owner_after orelse return false;
        if (owner.tag != .function_expression or owner.node.isNone() or @backingInt(owner.node) >= tree.nodes.items.len) return false;
        const actual = tree.getNode(owner.node);
        if (actual.tag != owner.tag or !std.meta.eql(actual.span, owner.span) or actual.data.extra != owner.words[0] or
            !tree.hasExtra(actual.data.extra, Ast.FunctionExtra.body)) return false;
        if (!tree.readExtraNode(actual.data.extra, Ast.FunctionExtra.name).isNone() or
            tree.readExtraNode(actual.data.extra, Ast.FunctionExtra.params) != event.owner_edges.parameters or
            tree.readExtraNode(actual.data.extra, Ast.FunctionExtra.body) != event.owner_edges.body or
            event.owner_edges.parameters.isNone() or event.owner_edges.body.isNone()) return false;
        if (tree.getNode(event.owner_edges.parameters).tag != .formal_parameters or tree.getNode(event.owner_edges.body).tag != .block_statement) return false;
    }
    return true;
}

/// Default-parameter lowering moves an already-created class IIFE from the
/// original parameter environment to that SAME source function's body. An
/// arbitrary descendant function is not a replacement evaluation environment.
fn parameterBodyReparent(tree: *const Ast.Ast, history: *const H.Index, target: Scope.ScopeId, epoch: u32, captured: Scope.Scope, current: Scope.Scope) bool {
    const initial = history.history.source_scopes;
    if (captured.parent.isNone() or current.parent.isNone() or captured.parent == current.parent or
        captured.parent.toIndex() >= initial.len or current.parent.toIndex() >= initial.len or
        initial[captured.parent.toIndex()].kind != .function or initial[current.parent.toIndex()].kind != .function or
        initial[current.parent.toIndex()].parent != captured.parent) return false;
    var adjusted = current;
    adjusted.parent = captured.parent;
    if (!@import("source_external_origin.zig").sameFrame(captured, adjusted)) return false;
    var parameters: ?H.Owner = null;
    var body: ?H.OwnerBinding = null;
    for (history.history.source_owners) |binding| {
        if (binding.scope == captured.parent) {
            if (parameters != null or binding.owner.tag != .formal_parameters) return false;
            parameters = binding.owner;
        }
        if (binding.scope == current.parent) {
            if (body != null) return false;
            switch (binding.owner.tag) {
                .function_declaration, .function_expression, .method_definition, .arrow_function_expression => {},
                else => return false,
            }
            body = binding;
        }
    }
    const parameter_owner = parameters orelse return false;
    const source_body = body orelse return false;
    if (source_body.edges.parameters != parameter_owner.node or source_body.edges.body.isNone() or
        @backingInt(source_body.edges.body) >= tree.nodes.items.len or tree.getNode(source_body.edges.body).tag != .block_statement) return false;
    const pslot: u32 = if (source_body.owner.tag == .arrow_function_expression) Ast.ArrowExtra.params else Ast.FunctionExtra.params;
    const bslot: u32 = if (source_body.owner.tag == .arrow_function_expression) Ast.ArrowExtra.body else Ast.FunctionExtra.body;
    if (!tree.hasExtra(source_body.owner.words[0], @max(pslot, bslot)) or
        tree.readExtraNode(source_body.owner.words[0], pslot) != parameter_owner.node or
        tree.readExtraNode(source_body.owner.words[0], bslot) != source_body.edges.body) return false;
    var body_owner: ?H.Owner = source_body.owner;
    var moved = false;
    for (history.history.events, 0..) |event, index| {
        if (event.scope == current.parent and (event.kind == .owner or event.kind == .birth)) body_owner = event.owner_after;
        if (index < epoch or event.scope != target or event.kind != .frame) continue;
        const before = event.before orelse return false;
        if (before.parent == event.after.parent) continue;
        if (moved or before.parent != captured.parent or event.after.parent != current.parent or
            event.trigger_scope != target or event.trigger_parent != current.parent or
            body_owner == null or !std.meta.eql(event.parent_owner, body_owner)) return false;
        var after = event.after;
        after.parent = before.parent;
        if (!@import("source_external_origin.zig").sameFrame(before, after)) return false;
        moved = true;
    }
    return moved;
}

/// Called only after the actual reserved IIFE function and its completed body
/// have been published. Replace exactly the provisional class-key scope move,
/// not unrelated relocation history or a field-initializer permission.
pub fn completeIife(self: anytype, class: Ast.NodeIndex, fragments: []const Ast.NodeIndex, target: Scope.ScopeId, owner: Ast.NodeIndex) std.mem.Allocator.Error!void {
    if (!self.semantic_edit_enabled or fragments.len == 0) return;
    const editor = &self.semantic_editor.?;
    const source_scope = self.outputOwnedScope(class) orelse @panic("class-key completion lost source owner");
    // Inferred anonymous names may copy the class header before lowering.
    // The owner-copy producer, not spelling or shared scope, supplies the
    // immutable initial class identity used by source_class_keys.
    const class_raw = @backingInt(class);
    const initial_raw = self.scope_owner_origins.get(class_raw) orelse
        if (class_raw < self.parser_node_count) class_raw else @panic("class-key completion lost source class lineage");
    if (initial_raw >= self.parser_node_count or self.scope_owner_map.get(initial_raw) != @backingInt(source_scope))
        @panic("class-key completion has a foreign initial class owner");
    if (initial_raw != class_raw and self.scope_owner_remaps.get(initial_raw) != class_raw)
        @panic("class-key completion lost its exact copied class owner");
    const initial_class: Ast.NodeIndex = @fromBackingInt(initial_raw);
    if (self.outputOwnedScope(owner) != target or self.ast.getNode(owner).tag != .function_expression) @panic("class-key completion lost actual IIFE owner");
    const body = self.ast.readExtraNode(self.ast.getNode(owner).data.extra, Ast.FunctionExtra.body);
    // One bounded iterative walk proves that each exact memo fragment is in
    // this completed body. Allocation failure propagates through the transaction.
    var reachable: std.AutoHashMapUnmanaged(Ast.NodeIndex, void) = .empty;
    defer reachable.deinit(self.allocator);
    var stack: std.ArrayList(Ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |node| {
        if (node.isNone()) continue;
        if (@backingInt(node) >= self.ast.nodes.items.len) @panic("class-key completion invalid body node");
        const slot = try reachable.getOrPut(self.allocator, node);
        if (slot.found_existing) continue;
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    for (fragments) |fragment| {
        if (!reachable.contains(fragment)) @panic("class-key memo is outside actual IIFE body");
        const reads = try @import("reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, fragment);
        defer self.allocator.free(reads);
        for (reads) |read| {
            var entry = editor.node_scope_provenance.get(read) orelse continue;
            var origin = entry.source_external orelse continue;
            if (origin.source_scope != source_scope or entry.scope != target) continue;
            if (origin.scope_moves.len == 0) @panic("class-key completion lost provisional move");
            const last = origin.scope_moves[origin.scope_moves.len - 1];
            if (last.reason != .lowerer_scope_relocation or last.from != source_scope or last.to != target or last.node != read or last.source_node != entry.source_node) @panic("class-key completion has foreign relocation");
            var selected: ?u32 = null;
            for (editor.scope_history.source_class_keys, 0..) |source, index| {
                if (source.scope != source_scope or source.class_owner.node != initial_class or source.leaf.node != entry.source_node) continue;
                if (selected != null) @panic("class-key completion has ambiguous source membership");
                selected = @intCast(index);
            }
            const index = selected orelse @panic("class-key completion lost source membership");
            if (self.getSymbolIdAt(read) != null or entry.external_import != null or entry.with_environment or !origin.flags.read or origin.flags.write or origin.flags.declare or origin.flags.type_context or origin.flags.value_as_type) @panic("class-key completion lost read authority");
            origin.scope_moves = origin.scope_moves[0 .. origin.scope_moves.len - 1];
            const epoch = editor.scope_history.epoch();
            entry.source_external = try @import("source_external_origin.zig").classKey(self.allocator, origin, read, entry.source_node, source_scope, target, editor.scopes.items, epoch, .{ .source_index = index, .evaluation_scope = target, .capture_epoch = epoch });
            try editor.node_scope_provenance.put(self.allocator, read, entry);
            try self.transformed_node_scope_provenance.put(self.allocator, read, entry);
            self.node_scope_provenance_changed = true;
        }
    }
}

pub fn apply(self: anytype, class: Ast.NodeIndex, fragment: Ast.NodeIndex, target: Scope.ScopeId) std.mem.Allocator.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = &self.semantic_editor.?;
    const source_scope = self.outputOwnedScope(class) orelse @panic("class-key hoist lost its exact source authority");
    const reads = try @import("reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, fragment);
    defer self.allocator.free(reads);
    for (reads) |read| {
        var entry = editor.node_scope_provenance.get(read) orelse continue;
        const origin = entry.source_external orelse continue;
        if (entry.scope != source_scope or origin.source_scope != source_scope) continue;
        if (self.getSymbolIdAt(read) != null or entry.external_import != null or entry.with_environment or !origin.flags.read or
            origin.flags.write or origin.flags.declare or origin.flags.type_context or origin.flags.value_as_type) @panic("class-key hoist lost its exact source authority");
        var selected: ?u32 = null;
        for (editor.scope_history.source_class_keys, 0..) |source, index| {
            if (source.scope != source_scope or source.class_owner.node != class or source.leaf.node != entry.source_node) continue;
            if (selected != null) @panic("class-key hoist lost its exact source authority");
            selected = @intCast(index);
        }
        const index = selected orelse @panic("class-key hoist lost its exact source authority");
        entry.scope = target;
        entry.source_external = try @import("source_external_origin.zig").classKey(self.allocator, origin, read, entry.source_node, source_scope, target, editor.scopes.items, editor.scope_history.epoch(), .{ .source_index = index, .evaluation_scope = target, .capture_epoch = editor.scope_history.epoch() });
        try editor.node_scope_provenance.put(self.allocator, read, entry);
        try self.transformed_node_scope_provenance.put(self.allocator, read, entry);
        self.node_scope_provenance_changed = true;
    }
}

test "class key hoisting authenticates source membership and paired scopes" {
    const Parser = @import("../parser/parser.zig").Parser;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Analyzer = @import("analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("../transformer/transformer.zig").Transformer;
    const External = @import("source_external_origin.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "class First{static[firstKey]=7}class Second{static[secondKey]=8}");
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    const parser_count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es5);
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const CaptureOom = struct {
        fn run(allocator: std.mem.Allocator, tree: *const Ast.Ast, scopes: []const Scope.Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) !void {
            var owned = try H.Recorder.init(allocator, tree, scopes, owners);
            defer owned.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 2), owned.source_class_keys.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, CaptureOom.run, .{ &parser.ast, analyzer.scopes.items, &analyzer.scope_owner_map });
    var t = try Transformer.initFromOwnedAst(a, &parser.ast, .{ .unsupported = @import("../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es5) });
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
    try std.testing.expect(External.validate(t.ast, parser_count, result.symbol_ids, result.scopes, &analyzer.unresolved_reference_nodes, &result.node_scope_provenance, &indexed));
    var entries = result.node_scope_provenance.iterator();
    var checked: usize = 0;
    while (entries.next()) |entry| {
        const origin = entry.value_ptr.source_external orelse continue;
        for (origin.scope_moves) |move| {
            const transfer = move.class_key orelse continue;
            try std.testing.expect(validates(t.ast, &indexed, parser_count, origin, move, transfer));
            const before_entry = entry.value_ptr.*;
            entry.value_ptr.with_environment = true;
            try std.testing.expect(!External.validate(t.ast, parser_count, result.symbol_ids, result.scopes, &analyzer.unresolved_reference_nodes, &result.node_scope_provenance, &indexed));
            entry.value_ptr.* = before_entry;
            const replay = try a.alloc(External.ScopeMove, origin.scope_moves.len + 1);
            @memcpy(replay[0..origin.scope_moves.len], origin.scope_moves);
            replay[origin.scope_moves.len] = move;
            entry.value_ptr.source_external.?.scope_moves = replay;
            try std.testing.expect(!External.validate(t.ast, parser_count, result.symbol_ids, result.scopes, &analyzer.unresolved_reference_nodes, &result.node_scope_provenance, &indexed));
            entry.value_ptr.* = before_entry;
            for (0..9) |poison| {
                var wrong_origin = origin;
                var wrong_move = move;
                var wrong_transfer = transfer;
                switch (poison) {
                    0 => wrong_transfer.source_index = @intCast(result.scope_history.source_class_keys.len),
                    1 => wrong_transfer.source_index = if (transfer.source_index == 0) 1 else 0,
                    2 => wrong_transfer.capture_epoch += 1,
                    3 => wrong_transfer.evaluation_scope = origin.source_scope,
                    4 => wrong_move.source_node = .none,
                    5 => wrong_origin.flags.write = true,
                    6 => wrong_origin.flags.declare = true,
                    7 => wrong_origin.execution_scope = move.to,
                    8 => wrong_origin.source_frame.subtree_has_direct_eval = true,
                    else => unreachable,
                }
                try std.testing.expect(!validates(t.ast, &indexed, parser_count, wrong_origin, wrong_move, wrong_transfer));
            }
            checked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), checked);
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const data: Data = .{
        .symbols = result.symbols,
        .scopes = result.scopes,
        .scope_maps = result.scope_maps,
        .scope_owner_map = result.scope_owner_map,
        .symbol_ids = result.symbol_ids,
        .references = result.references,
        .exported_names = analyzer.exported_names,
        .unresolved_references = analyzer.unresolved_references,
        .helper_scope_map = result.helper_scope_map,
        .node_scope_provenance = result.node_scope_provenance,
        .scope_history = result.scope_history,
        .source_owned_retirements = result.source_owned_retirements,
    };
    const Codec = @import("../bundler/semantic_codec.zig");
    var wire: std.ArrayList(u8) = .empty;
    try Codec.serialize(&data, &wire, a);
    var decoded = try Codec.deserialize(wire.items, a);
    try std.testing.expectEqual(@as(usize, 2), decoded.scope_history.source_class_keys.len);
    try std.testing.expect(std.meta.eql(data.scope_history.source_class_keys[0], decoded.scope_history.source_class_keys[0]));
    const backing = decoded.scope_history.source_class_keys.ptr;
    var recorder = try H.Recorder.fromHistory(a, decoded.scope_history);
    decoded.scope_history = try recorder.finish(a);
    try std.testing.expect(backing != decoded.scope_history.source_class_keys.ptr);
    const decoded_index = try H.validateAndIndex(a, t.ast, decoded.scopes, &decoded.scope_owner_map, &decoded.scope_history, null);
    try std.testing.expect(decoded_index.valid);
    try std.testing.expect(External.validate(t.ast, parser_count, decoded.symbol_ids, decoded.scopes, &analyzer.unresolved_reference_nodes, &decoded.node_scope_provenance, &decoded_index));
    var edit = try decoded.beginEdit(a, t.ast);
    decoded.applyEdit(try edit.finish());
    const edited_index = try H.validateAndIndex(a, t.ast, decoded.scopes, &decoded.scope_owner_map, &decoded.scope_history, null);
    try std.testing.expect(edited_index.valid);
    try std.testing.expect(External.validate(t.ast, parser_count, decoded.symbol_ids, decoded.scopes, &analyzer.unresolved_reference_nodes, &decoded.node_scope_provenance, &edited_index));
    const Oom = struct {
        fn run(allocator: std.mem.Allocator, history: H.History) !void {
            var owned = try H.Recorder.fromHistory(allocator, history);
            defer owned.deinit(allocator);
            try std.testing.expect(owned.source_class_keys.ptr != history.source_class_keys.ptr);
            try std.testing.expect(std.meta.eql(owned.source_class_keys[0], history.source_class_keys[0]));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Oom.run, .{data.scope_history});
}
