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
    if (initial.parent != move.to or initial.kind != .class_body or initial.blocksMangling() or !initial.is_strict) return false;
    // The immutable source class/member/key relation is independent of the
    // lowered temporary. Never reconstruct a declaration by its spelling.
    if (source.member.words[0] >= tree.extra_data.items.len or tree.extra_data.items[source.member.words[0]] != @backingInt(source.key.node)) return false;
    return transfer.source_index < history.class_key_read_membership.len and history.class_key_read_membership[transfer.source_index];
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
