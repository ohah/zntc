//! Capture the exposed lexical binding before the actual enum erasure.
//! This is source resolution, never a lookup in final emitted names.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Symbol = @import("../semantic/symbol.zig");
const Retirement = @import("../semantic/source_owned_retirement.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;

pub const Plan = struct {
    witness: Retirement.Witness,
    target: Symbol.SymbolId,
    target_declaration: Symbol.Reference,
    target_node: Ast.Node,
    reads: []const Symbol.Reference,
};

fn declarationFor(refs: []const Symbol.Reference, sid: Symbol.SymbolId) ?Symbol.Reference {
    var found: ?Symbol.Reference = null;
    for (refs) |row| if (row.symbol_id == sid and row.flags.declare) {
        if (found != null or row.declaration_node_index.isNone()) return null;
        found = row;
    };
    return found;
}

/// Resolve only the original lexical maps, skipping the one erased identity.
/// A nearer conflicting carrier is authoritative even if it is unsupported.
fn exposedSourceBinding(self: anytype, origin: @import("../semantic/scope.zig").ScopeId, erased: Symbol.SymbolId, name: []const u8) ?Symbol.SymbolId {
    var scope = self.scopes[origin.toIndex()].parent;
    var fuel = self.scopes.len;
    while (!scope.isNone() and fuel > 0) : (fuel -= 1) {
        if (scope.toIndex() >= self.scopes.len or scope.toIndex() >= self.scope_maps.len or self.scopes[scope.toIndex()].blocksMangling()) return null;
        var entries = self.scope_maps[scope.toIndex()].iterator();
        while (entries.next()) |entry| {
            if (Scanner.identifierNamesEqual(entry.key_ptr.*, name)) {
                if (entry.value_ptr.* == @backingInt(erased)) break;
                if (entry.value_ptr.* >= self.symbols.len) return null;
                return @fromBackingInt(@as(u32, @intCast(entry.value_ptr.*)));
            }
        }
        scope = self.scopes[scope.toIndex()].parent;
    }
    return null;
}

pub fn capture(self: anytype) !void {
    try captureDeclarationSources(self);
    if (!self.detach_erased_const_enum_external_reads) return;
    const tree = self.ast;
    for (tree.nodes.items[0..self.parser_node_count], 0..) |node, raw| {
        if (node.tag != .ts_enum_declaration or !tree.hasExtra(node.data.extra, Ast.EnumExtra.flags) or tree.readExtra(node.data.extra, Ast.EnumExtra.flags) != 1) continue;
        const binding: Ast.NodeIndex = @fromBackingInt(tree.readExtra(node.data.extra, Ast.EnumExtra.name));
        if (binding.isNone() or @backingInt(binding) >= self.symbol_ids.items.len) continue;
        const sid = self.symbol_ids.items[@backingInt(binding)] orelse continue;
        if (sid >= self.symbols.len) continue;
        const before = self.symbols[sid];
        if (before.isExported() or before.isSynthetic() or before.scope_id.isNone() or before.scope_id.toIndex() >= self.scopes.len or self.scopes[before.scope_id.toIndex()].blocksMangling()) continue;
        const declaration = declarationFor(self.references, @fromBackingInt(sid)) orelse continue;
        if (declaration.declaration_node_index != binding or tree.getNode(binding).tag != .binding_identifier) continue;
        const name = tree.identifierNameText(tree.getNode(binding));
        const target_sid = exposedSourceBinding(self, before.scope_id, @fromBackingInt(sid), name) orelse continue;
        const target_decl = declarationFor(self.references, target_sid) orelse continue;
        const target_node = tree.getNode(target_decl.declaration_node_index);
        if (target_node.tag != .binding_identifier) continue;
        var reads: std.ArrayList(Symbol.Reference) = .empty;
        errdefer reads.deinit(self.allocator);
        var safe = true;
        for (self.references) |row| if (@backingInt(row.symbol_id) == sid and !row.flags.declare) {
            if (row.node_index.isNone() or !row.flags.read or row.flags.write or row.flags.type_context or row.flags.value_as_type or tree.getNode(row.node_index).tag != .identifier_reference) {
                safe = false;
                break;
            }
            try reads.append(self.allocator, row);
        };
        if (!safe or reads.items.len == 0) {
            reads.deinit(self.allocator);
            continue;
        }
        const owned_reads = try reads.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_reads);
        try self.erased_const_enum_binding_handoffs.append(self.allocator, .{
            .witness = .{ .symbol_id = @fromBackingInt(sid), .before = before, .declaration = declaration, .declaration_node = tree.getNode(binding), .source_owner = @fromBackingInt(@as(u32, @intCast(raw))), .source_owner_node = node, .source_scope = before.scope_id, .source_parent = self.scopes[before.scope_id.toIndex()].parent, .source_name = binding, .source_name_symbol = @fromBackingInt(sid), .closure_scope = .none, .closure_parent = .none, .reason = .erased_const_enum_binding },
            .target = target_sid,
            .target_declaration = target_decl,
            .target_node = target_node,
            .reads = owned_reads,
        });
    }
}

pub fn apply(self: anytype, editor: anytype, live: *const std.AutoHashMapUnmanaged(u32, void)) !void {
    for (self.erased_const_enum_binding_handoffs.items) |plan| {
        const w = plan.witness;
        const sid = @backingInt(w.symbol_id);
        if (live.contains(@backingInt(w.source_owner)) or live.contains(@backingInt(w.source_name))) continue;
        if (sid >= editor.symbols.items.len or @backingInt(plan.target) >= editor.symbols.items.len) return error.InvalidSymbol;
        var before = w.before;
        before.reference_count = editor.symbols.items[sid].reference_count;
        before.write_count = editor.symbols.items[sid].write_count;
        if (!Retirement.equalSymbol(before, editor.symbols.items[sid])) return error.InvalidSymbol;
        const source_binding = w.declaration_node orelse return error.InvalidSymbol;
        const source_name = self.ast.identifierNameText(source_binding);
        if (!Scanner.identifierNamesEqual(self.ast.identifierNameText(plan.target_node), source_name) or
            exposedSourceBinding(self, w.source_scope, w.symbol_id, source_name) != plan.target) return error.InvalidSymbol;
        const original_target = declarationFor(self.references, plan.target) orelse return error.InvalidSymbol;
        if (!std.meta.eql(original_target, plan.target_declaration)) return error.InvalidSymbol;
        var target_found = false;
        for (editor.references.items) |row| if (row.flags.declare and row.symbol_id == plan.target and row.declaration_node_index == plan.target_declaration.declaration_node_index) {
            target_found = true;
            break;
        };
        if (!target_found or !@import("../semantic/import_erasure.zig").equalNode(self.ast.getNode(plan.target_declaration.declaration_node_index), plan.target_node)) return error.InvalidSymbol;
        var nodes: std.ArrayList(Ast.NodeIndex) = .empty;
        defer nodes.deinit(self.allocator);
        for (editor.references.items) |row| if (row.symbol_id == w.symbol_id and !row.flags.declare) {
            if (row.node_index.isNone() or !live.contains(@backingInt(row.node_index))) continue;
            const source = self.reference_origin_map.get(@backingInt(row.node_index)) orelse @backingInt(row.node_index);
            var matched = false;
            for (plan.reads) |original| if (@backingInt(original.node_index) == source and std.meta.eql(original.flags, row.flags)) {
                matched = true;
                break;
            };
            if (!matched) return error.InvalidSymbol;
            try nodes.append(self.allocator, row.node_index);
        };
        for (nodes.items) |node| {
            try editor.rebindReference(node, plan.target);
            self.symbol_ids.items[@backingInt(node)] = @backingInt(plan.target);
        }
        // No new identity is minted: remove only this captured erased source
        // declaration and its exact map/slot edges, retaining its typed witness.
        var write: usize = 0;
        var declarations: usize = 0;
        for (editor.references.items) |row| {
            if (row.symbol_id == w.symbol_id) {
                // Statement coordinates are recomputed by the actual output
                // producer; the source declaration authority is its SID,
                // lexical scope and role flags. Enum erasure already clears
                // the old binding carrier; the pre-erasure plan retains it
                // and both that binding and its exact enum owner are dead.
                if (!row.flags.declare or row.symbol_id != w.declaration.symbol_id or row.scope_id != w.declaration.scope_id or
                    row.node_index != w.declaration.node_index or
                    (!row.declaration_node_index.isNone() and row.declaration_node_index != w.declaration.declaration_node_index) or
                    !std.meta.eql(row.flags, w.declaration.flags)) return error.InvalidSymbol;
                declarations += 1;
                continue;
            }
            editor.references.items[write] = row;
            write += 1;
        }
        if (declarations != 1 or editor.symbols.items[sid].reference_count != 0 or editor.symbols.items[sid].write_count != 0) return error.InvalidSymbol;
        editor.references.shrinkRetainingCapacity(write);
        editor.reference_index.clearRetainingCapacity();
        editor.reference_index_built = false;
        for (editor.scope_maps.items) |*map| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.allocator);
            var entries = map.iterator();
            while (entries.next()) |entry| if (entry.value_ptr.* == sid) try keys.append(self.allocator, entry.key_ptr.*);
            for (keys.items) |key| _ = map.remove(key);
        }
        for (editor.symbol_ids.items, 0..) |*id, raw| if (id.* == sid) {
            if (live.contains(@intCast(raw))) return error.InvalidSymbol;
            id.* = null;
        };
        for (self.symbol_ids.items) |*id| if (id.* == sid) {
            id.* = null;
        };
        if (editor.source_owned_retirements.contains(sid)) return error.InvalidSymbol;
        try editor.source_owned_retirements.put(self.allocator, sid, w);
    }
}

test "erased const enum source handoff retains exact declaration witnesses across codec and rejects paired owners" {
    const Parser = @import("../parser/parser.zig").Parser;
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("transformer.zig").Transformer;
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    const source = "let Status={Ready:78};function first(){const enum Status{Ready=42}return typeof Status}function second(){const enum Status{Ready=43}return typeof Status}console.log(first(),second());";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".unknown");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const parser_count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var transformer = try Transformer.initFromOwnedAst(a, &parser.ast, .{});
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
    transformer.detach_erased_const_enum_external_reads = true;
    transformer.record_explicit_global_references = true;
    const root = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 2), transformer.erased_const_enum_binding_handoffs.items.len);
    const edited = (try transformer.finishSemanticEdit()).?;
    var data: Data = .{ .symbols = edited.symbols, .scopes = edited.scopes, .scope_maps = edited.scope_maps, .scope_owner_map = edited.scope_owner_map, .symbol_ids = edited.symbol_ids, .references = edited.references, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .helper_scope_map = edited.helper_scope_map, .node_scope_provenance = edited.node_scope_provenance, .scope_history = edited.scope_history, .source_owned_retirements = edited.source_owned_retirements };
    const Check = struct {
        fn run(alloc: std.mem.Allocator, tree: *const Ast.Ast, output: Ast.NodeIndex, count: u32, sem: *const Data, unresolved: *const std.AutoHashMapUnmanaged(u32, void), producer: *const Transformer) !bool {
            var report = try @import("symbol_coverage.zig").checkOutputNormalFormQuiet(alloc, tree, output, count, sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, producer.helper_ref_nodes.items, &sem.helper_scope_map, unresolved, &producer.explicit_global_reference_nodes, &producer.reference_origin_map, .{ .pre_transform_scope_count = sem.scope_history.source_scopes.len }, &sem.source_owned_retirements, .{ .node_scope_provenance = &sem.node_scope_provenance, .scope_history = &sem.scope_history, .runtime_helper_symbols = &producer.runtime_helper_symbol_ids, .class_self_symbols = &producer.class_self_symbol_map });
            defer report.deinit(alloc);
            return report.hasCompleteOutputIdentityBeforeNames();
        }
    };
    var binding_count: usize = 0;
    var environment_count: usize = 0;
    var states = data.source_owned_retirements.valueIterator();
    while (states.next()) |state| {
        if (state.reason == .erased_const_enum_binding) binding_count += 1 else if (state.reason == .erased_const_enum_environment) environment_count += 1 else return error.UnexpectedRetirement;
    }
    try std.testing.expectEqual(@as(usize, 2), binding_count);
    try std.testing.expectEqual(@as(usize, 2), environment_count);
    try std.testing.expectEqual(@as(u32, 4), data.source_owned_retirements.count());
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    var environments: [2]Retirement.Witness = undefined;
    var environment_index: usize = 0;
    var environment_states = data.source_owned_retirements.valueIterator();
    while (environment_states.next()) |state| if (state.reason == .erased_const_enum_environment) {
        environments[environment_index] = state.*;
        environment_index += 1;
    };
    const environment = environments[0];
    const other_environment = environments[1];
    const environment_sid = @backingInt(environment.symbol_id);
    for (0..14) |which| {
        var poison = environment;
        var birth = poison.enum_environment.?;
        switch (which) {
            0 => poison.source_owner = other_environment.source_owner,
            1 => poison.source_scope = other_environment.source_scope,
            2 => poison.source_name = other_environment.source_name,
            3 => poison.source_name_symbol = other_environment.source_name_symbol,
            4 => birth.parameter_symbol = other_environment.symbol_id,
            5 => birth.owner = other_environment.enum_environment.?.owner,
            6 => birth.binding_declaration = other_environment.enum_environment.?.binding_declaration,
            7 => birth.binding_node = other_environment.enum_environment.?.binding_node,
            8 => poison.before.synthetic_kind = .implicit_arguments,
            9 => poison.declaration = other_environment.declaration,
            10 => poison.closure_parent = other_environment.source_scope,
            11 => {
                poison.source_owner = other_environment.source_owner;
                poison.source_owner_node = other_environment.source_owner_node;
                poison.source_name = other_environment.source_name;
                birth.owner = other_environment.enum_environment.?.owner;
                birth.binding_node = other_environment.enum_environment.?.binding_node;
                birth.binding_declaration = other_environment.enum_environment.?.binding_declaration;
            },
            12 => poison.before.origin_scope = other_environment.source_scope,
            13 => poison.reason = .source_function_closure,
            else => unreachable,
        }
        poison.enum_environment = birth;
        data.source_owned_retirements.getPtr(environment_sid).?.* = poison;
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        data.source_owned_retirements.getPtr(environment_sid).?.* = environment;
    }
    const plan = transformer.erased_const_enum_binding_handoffs.items[0];
    const other = transformer.erased_const_enum_binding_handoffs.items[1].witness;
    const sid = @backingInt(plan.witness.symbol_id);
    for (0..12) |which| {
        var poison = plan.witness;
        switch (which) {
            0 => poison.symbol_id = plan.target,
            1 => poison.source_owner = other.source_owner,
            2 => poison.source_owner_node = other.source_owner_node,
            3 => poison.source_name = other.source_name,
            4 => poison.source_name_symbol = plan.target,
            5 => poison.source_scope = other.source_scope,
            6 => poison.source_parent = other.source_scope,
            7 => poison.declaration = other.declaration,
            8 => poison.declaration_node = other.declaration_node,
            9 => poison.before.name = other.before.name,
            10 => {
                poison.source_owner = other.source_owner;
                poison.source_owner_node = other.source_owner_node;
                poison.source_name = other.source_name;
                poison.declaration_node = other.declaration_node;
            },
            11 => poison.reason = .source_function_closure,
            else => unreachable,
        }
        data.source_owned_retirements.getPtr(sid).?.* = poison;
        try std.testing.expect(!try Check.run(a, transformer.ast, root, parser_count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        data.source_owned_retirements.getPtr(sid).?.* = plan.witness;
    }
    var wire: std.ArrayList(u8) = .empty;
    try @import("../bundler/semantic_codec.zig").serialize(&data, &wire, a);
    var restored = try @import("../bundler/semantic_codec.zig").deserialize(wire.items, a);
    try std.testing.expect(try Check.run(a, transformer.ast, root, parser_count, &restored, &analyzer.unresolved_reference_nodes, &transformer));
}

pub const DeclarationSource = struct {
    witness: Retirement.Witness,
    declarations: []const Symbol.Reference,
};

fn captureDeclarationSources(self: anytype) !void {
    if (!self.semantic_edit_enabled or !self.ast.has_ts_namespace_or_enum) return;
    const Candidate = struct { witness: Retirement.Witness, rows: std.ArrayList(Symbol.Reference) = .empty, primary: bool = false };
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |*candidate| candidate.rows.deinit(self.allocator);
        candidates.deinit(self.allocator);
    }
    var by_symbol: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer by_symbol.deinit(self.allocator);
    var enum_bindings: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer enum_bindings.deinit(self.allocator);
    for (self.ast.nodes.items[0..self.parser_node_count], 0..) |node, raw| {
        if (node.tag != .ts_enum_declaration or !self.ast.hasExtra(node.data.extra, Ast.EnumExtra.flags) or
            self.ast.readExtra(node.data.extra, Ast.EnumExtra.flags) != 1) continue;
        const binding = self.ast.readExtraNode(node.data.extra, Ast.EnumExtra.name);
        if (binding.isNone() or @backingInt(binding) >= self.symbol_ids.items.len or self.ast.getNode(binding).tag != .binding_identifier) continue;
        const sid = self.symbol_ids.items[@backingInt(binding)] orelse continue;
        if (sid >= self.symbols.len) continue;
        try enum_bindings.put(self.allocator, @backingInt(binding), sid);
        if (by_symbol.contains(sid)) continue;
        const before = self.symbols[sid];
        if ((before.kind != .variable_let and before.kind != .variable_var) or before.isExported() or before.isSynthetic() or
            before.synthetic_name.len != 0 or before.output_name_hint.len != 0 or before.synthetic_owner_id != null or
            before.scope_id.isNone() or before.scope_id.toIndex() >= self.scopes.len or before.origin_scope != before.scope_id or
            self.scopes[before.scope_id.toIndex()].blocksMangling() or !std.meta.eql(before.declaration_span, node.span)) continue;
        const candidate_index = candidates.items.len;
        try candidates.append(self.allocator, .{ .witness = .{ .symbol_id = @fromBackingInt(sid), .before = before, .declaration = undefined, .declaration_node = self.ast.getNode(binding), .source_owner = @fromBackingInt(@as(u32, @intCast(raw))), .source_owner_node = node, .source_scope = before.scope_id, .source_parent = self.scopes[before.scope_id.toIndex()].parent, .source_name = binding, .source_name_symbol = @fromBackingInt(sid), .closure_scope = .none, .closure_parent = .none, .reason = .erased_const_enum_binding } });
        try by_symbol.put(self.allocator, sid, candidate_index);
    }
    for (self.references) |row| {
        if (!row.flags.declare or row.declaration_node_index.isNone()) continue;
        const sid = @backingInt(row.symbol_id);
        const index = by_symbol.get(sid) orelse continue;
        if (enum_bindings.get(@backingInt(row.declaration_node_index)) != sid) continue;
        const candidate = &candidates.items[index];
        if (row.scope_id != candidate.witness.before.scope_id or !row.node_index.isNone() or
            !std.meta.eql(row.flags, @as(Symbol.ReferenceFlags, .{ .declare = true }))) continue;
        try candidate.rows.append(self.allocator, row);
        if (row.declaration_node_index == candidate.witness.source_name) {
            candidate.primary = true;
            candidate.witness.declaration = row;
        }
    }
    for (candidates.items) |*candidate| {
        if (!candidate.primary) continue;
        const owned = try candidate.rows.toOwnedSlice(self.allocator);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(owned);
        try self.erased_const_enum_declaration_sources.append(self.allocator, .{ .witness = candidate.witness, .declarations = owned });
        transferred = true;
        for (self.ast.nodes.items[0..self.parser_node_count], 0..) |enum_node, raw| {
            if (enum_node.tag != .ts_enum_declaration or !self.ast.hasExtra(enum_node.data.extra, Ast.EnumExtra.flags) or
                self.ast.readExtra(enum_node.data.extra, Ast.EnumExtra.flags) != 1) continue;
            const binding = self.ast.readExtraNode(enum_node.data.extra, Ast.EnumExtra.name);
            if (enum_bindings.get(@backingInt(binding)) != @backingInt(candidate.witness.symbol_id)) continue;
            var owner_witness = candidate.witness;
            owner_witness.source_owner = @fromBackingInt(@as(u32, @intCast(raw)));
            owner_witness.source_owner_node = enum_node;
            owner_witness.source_name = binding;
            owner_witness.declaration_node = self.ast.getNode(binding);
            for (owned) |row| if (row.declaration_node_index == binding) {
                owner_witness.declaration = row;
                break;
            };
            if (owner_witness.declaration.declaration_node_index != binding) invalidEnvironmentSource();
            try captureEnvironment(self, owner_witness);
        }
    }
}

pub fn retireDeclarations(self: anytype, editor: anytype, live: *const std.AutoHashMapUnmanaged(u32, void)) !void {
    for (self.erased_const_enum_declaration_sources.items) |source| {
        const w = source.witness;
        const sid = @backingInt(w.symbol_id);
        if (w.reason == .erased_const_enum_environment) {
            try retireEnvironment(self, editor, live, w);
            continue;
        }
        if (editor.source_owned_retirements.get(sid)) |published| {
            if (published.reason != .erased_const_enum_binding or published.source_owner != w.source_owner or
                published.source_name != w.source_name or !Retirement.equalSymbol(published.before, w.before)) return error.InvalidSymbol;
            continue;
        }
        if (sid >= editor.symbols.items.len or live.contains(@backingInt(w.source_owner))) continue;
        for (source.declarations, 0..) |captured, capture_index| {
            const binding = captured.declaration_node_index;
            var already_selected = false;
            var expected_count: usize = 0;
            for (source.declarations, 0..) |other, other_index| if (other.declaration_node_index == binding) {
                expected_count += 1;
                if (other_index < capture_index) already_selected = true;
            };
            if (already_selected) continue;
            if (live.contains(@backingInt(binding))) continue;
            if (@backingInt(binding) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(binding)] != sid) return error.InvalidSymbol;
            var count: usize = 0;
            var write: usize = 0;
            for (editor.references.items) |row| {
                if (row.flags.declare and row.declaration_node_index == binding) {
                    if (row.symbol_id != captured.symbol_id or row.scope_id != captured.scope_id or row.node_index != captured.node_index or
                        !std.meta.eql(row.flags, captured.flags)) return error.InvalidSymbol;
                    count += 1;
                    continue;
                }
                editor.references.items[write] = row;
                write += 1;
            }
            if (count != expected_count) return error.ReferenceNotFound;
            editor.references.shrinkRetainingCapacity(write);
            editor.reference_index.clearRetainingCapacity();
            editor.reference_index_built = false;
            editor.symbol_ids.items[@backingInt(binding)] = null;
            self.symbol_ids.items[@backingInt(binding)] = null;
        }
        var remains = false;
        for (editor.references.items) |row| if (@backingInt(row.symbol_id) == sid) {
            remains = true;
            break;
        };
        for (editor.symbol_ids.items, 0..) |id, raw| if (id == sid and live.contains(@intCast(raw))) {
            remains = true;
            break;
        };
        if (remains) continue;
        var expected = w.before;
        expected.reference_count = 0;
        expected.write_count = 0;
        if (!Retirement.equalSymbol(expected, editor.symbols.items[sid])) return error.InvalidSymbol;
        for (editor.scope_maps.items) |*map| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.allocator);
            var pairs = map.iterator();
            while (pairs.next()) |entry| if (entry.value_ptr.* == sid) try keys.append(self.allocator, entry.key_ptr.*);
            for (keys.items) |key| _ = map.remove(key);
        }
        for (editor.symbol_ids.items, 0..) |*id, raw| if (id.* == sid) {
            if (live.contains(@intCast(raw))) return error.InvalidSymbol;
            id.* = null;
        };
        for (self.symbol_ids.items) |*id| if (id.* == sid) {
            id.* = null;
        };
        try editor.source_owned_retirements.put(self.allocator, sid, w);
    }
}

fn invalidEnvironmentSource() noreturn {
    std.debug.panic("const enum environment lacks its exact initial declaration authority", .{});
}

fn captureEnvironment(self: anytype, outer: Retirement.Witness) std.mem.Allocator.Error!void {
    const scope_raw = self.scope_owner_map.get(@backingInt(outer.source_owner)) orelse return;
    if (scope_raw >= self.scopes.len) invalidEnvironmentSource();
    const scope = self.scopes[scope_raw];
    if (scope.kind != .function or scope.parent != outer.source_scope or scope.blocksMangling()) invalidEnvironmentSource();
    var parameter: ?Symbol.SymbolId = null;
    for (self.symbols, 0..) |symbol, raw| if (@backingInt(symbol.scope_id) == scope_raw and symbol.synthetic_kind == .enum_iife_parameter) {
        if (parameter != null) invalidEnvironmentSource();
        parameter = @fromBackingInt(@as(u32, @intCast(raw)));
    };
    const parameter_sid = parameter orelse invalidEnvironmentSource();
    const birth_owner = (@import("../semantic/scope_frame_history.zig").Owner.capture(self.ast, outer.source_owner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => invalidEnvironmentSource(),
    }) orelse invalidEnvironmentSource();
    for (self.references) |row| {
        if (!row.flags.declare or @backingInt(row.scope_id) != scope_raw) continue;
        const sid = @backingInt(row.symbol_id);
        if (sid >= self.symbols.len) invalidEnvironmentSource();
        const before = self.symbols[sid];
        if (before.synthetic_kind != .enum_iife_parameter and before.synthetic_kind != .implicit_arguments) continue;
        if (!row.node_index.isNone() or !row.declaration_node_index.isNone() or
            !std.meta.eql(row.flags, @as(Symbol.ReferenceFlags, .{ .declare = true }))) invalidEnvironmentSource();
        const empty = try self.allocator.alloc(Symbol.Reference, 0);
        errdefer self.allocator.free(empty);
        try self.erased_const_enum_declaration_sources.append(self.allocator, .{ .declarations = empty, .witness = .{
            .symbol_id = row.symbol_id,
            .before = before,
            .declaration = row,
            .declaration_node = null,
            .source_owner = outer.source_owner,
            .source_owner_node = outer.source_owner_node,
            .source_scope = row.scope_id,
            .source_parent = scope.parent,
            .source_name = outer.source_name,
            .source_name_symbol = outer.symbol_id,
            .closure_scope = row.scope_id,
            .closure_parent = scope.parent,
            .reason = .erased_const_enum_environment,
            .enum_environment = .{ .owner = birth_owner, .parameter_symbol = parameter_sid, .binding_declaration = outer.declaration, .binding_node = outer.declaration_node.? },
        } });
    }
}

fn retireEnvironment(self: anytype, editor: anytype, live: *const std.AutoHashMapUnmanaged(u32, void), w: Retirement.Witness) !void {
    if (live.contains(@backingInt(w.source_owner))) return;
    if (!editor.source_owned_retirements.contains(@backingInt(w.source_name_symbol))) return error.InvalidSymbol;
    const sid = @backingInt(w.symbol_id);
    if (sid >= editor.symbols.items.len or editor.source_owned_retirements.contains(sid)) return error.InvalidSymbol;
    var expected = w.before;
    expected.reference_count = 0;
    expected.write_count = 0;
    if (!Retirement.equalSymbol(expected, editor.symbols.items[sid])) return error.InvalidSymbol;
    var declarations: usize = 0;
    var write: usize = 0;
    for (editor.references.items) |row| {
        if (row.symbol_id == w.symbol_id) {
            if (row.scope_id != w.declaration.scope_id or row.node_index != w.declaration.node_index or
                row.declaration_node_index != w.declaration.declaration_node_index or !std.meta.eql(row.flags, w.declaration.flags)) return error.InvalidSymbol;
            declarations += 1;
            continue;
        }
        editor.references.items[write] = row;
        write += 1;
    }
    if (declarations != 1) return error.ReferenceNotFound;
    for (editor.symbol_ids.items) |id| if (id == sid) return error.InvalidSymbol;
    editor.references.shrinkRetainingCapacity(write);
    editor.reference_index.clearRetainingCapacity();
    editor.reference_index_built = false;
    for (editor.scope_maps.items) |*map| {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        var entries = map.iterator();
        while (entries.next()) |entry| if (entry.value_ptr.* == sid) try keys.append(self.allocator, entry.key_ptr.*);
        for (keys.items) |key| _ = map.remove(key);
    }
    if (editor.scope_owner_map.get(@backingInt(w.source_owner))) |scope| {
        if (scope != @backingInt(w.source_scope)) return error.InvalidScope;
        _ = try editor.removeScopeOwner(w.source_owner);
    }
    try editor.source_owned_retirements.put(self.allocator, sid, w);
}

test "erased const enum environment capture keeps source graph unchanged across heap OOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "const enum Kind{Left=3}const enum Kind{Right=4}console.log(Kind.Left+Kind.Right);";
    var scanner = try Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const original_nodes = try a.dupe(u8, std.mem.sliceAsBytes(parser.ast.nodes.items));
    const original_symbols = try a.dupe(u8, std.mem.sliceAsBytes(analyzer.symbols.items));
    const original_references = try a.dupe(u8, std.mem.sliceAsBytes(analyzer.references.items));
    const original_scopes = try a.dupe(u8, std.mem.sliceAsBytes(analyzer.scopes.items));
    var failures: usize = 0;
    var success = false;
    for (0..128) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = offset });
        var trial_ast = try parser.ast.cloneForTransformer(std.testing.allocator);
        defer trial_ast.deinit();
        var transformer = try @import("transformer.zig").Transformer.initFromOwnedAst(std.testing.allocator, &trial_ast, .{});
        try transformer.initSymbolIdsOwned(&trial_ast, analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.scope_history = analyzer.scope_history;
        transformer.semantic_edit_enabled = true;
        transformer.allocator = failing.allocator();
        defer transformer.deinit();
        const accepted = result: {
            capture(&transformer) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                break :result false;
            };
            break :result true;
        };
        try std.testing.expect(parser.ast.transform_boundary == null);
        try std.testing.expectEqualSlices(u8, original_nodes, std.mem.sliceAsBytes(parser.ast.nodes.items));
        try std.testing.expectEqualSlices(u8, original_nodes, std.mem.sliceAsBytes(trial_ast.nodes.items));
        try std.testing.expectEqualSlices(u8, original_symbols, std.mem.sliceAsBytes(analyzer.symbols.items));
        try std.testing.expectEqualSlices(u8, original_references, std.mem.sliceAsBytes(analyzer.references.items));
        try std.testing.expectEqualSlices(u8, original_scopes, std.mem.sliceAsBytes(analyzer.scopes.items));
        try std.testing.expectEqual(@as(u32, 0), analyzer.source_owned_retirements.count());
        if (accepted) {
            try std.testing.expectEqual(@as(usize, 3), transformer.erased_const_enum_declaration_sources.items.len);
            success = true;
            break;
        }
    }
    try std.testing.expect(failures > 0 and success);
    std.debug.print("ENUM_SOURCE_CAPTURE_HEAP_OOM failures={d} success={}\n", .{ failures, success });
}
