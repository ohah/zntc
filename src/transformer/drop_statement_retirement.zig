//! Source facts captured at the actual explicit drop-option decision.
//! A block is never presented as a source-owned function closure.
const std = @import("std");
const Ast = @import("../parser/ast.zig");
const Symbol = @import("../semantic/symbol.zig");
const Scope = @import("../semantic/scope.zig");
const History = @import("../semantic/scope_frame_history.zig");
const Registry = @import("../semantic/source_drop_registry.zig");

pub const Declaration = struct {
    before: Symbol.Symbol,
    row: Symbol.Reference,
    binding_node: ?Ast.Node,
    attached_symbol: ?u32,
    exposed_bindings: []const Symbol.SymbolId = &.{},
};
pub const Owner = struct {
    scope: Scope.ScopeId,
    frame: Scope.Scope,
    owner: History.Owner,
    history_index: ?u32,
};
pub const Source = struct {
    statement: Ast.NodeIndex,
    statement_node: Ast.Node,
    original: Registry.Node,
    action: Registry.Action,
    entry_epoch: u32,
    registry_index: ?u32 = null,
    edges: []const Registry.Edge,
    nodes: []const u32,
    declarations: []const Declaration,
    references: []const Symbol.Reference,
    owners: []const Owner,

    pub fn deinit(self: Source, a: std.mem.Allocator) void {
        a.free(self.nodes);
        a.free(self.edges);
        for (self.declarations) |declaration| a.free(declaration.exposed_bindings);
        a.free(self.declarations);
        a.free(self.references);
        a.free(self.owners);
    }
};

/// Capture the actual source before the transformer visits any children.
/// The allocator owns the ledger; the AST and graph remain untouched.
pub fn capture(self: anytype, statement: Ast.NodeIndex) std.mem.Allocator.Error!Source {
    const a = self.allocator;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, self.ast, statement);
    errdefer a.free(nodes);
    var selected: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer selected.deinit(a);
    try selected.ensureTotalCapacity(a, @intCast(nodes.len));
    for (nodes) |raw| selected.putAssumeCapacity(raw, {});
    var owners: std.ArrayList(Owner) = .empty;
    errdefer owners.deinit(a);
    var owner_entries = self.scope_owner_map.iterator();
    while (owner_entries.next()) |entry| {
        if (!selected.contains(entry.key_ptr.*)) continue;
        const scope = entry.value_ptr.*;
        if (scope >= self.scopes.len) std.debug.panic("dropped source owner has an invalid scope", .{});
        const owner = History.Owner.capture(self.ast, @fromBackingInt(entry.key_ptr.*)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("dropped source owner lost its original payload", .{}),
        };
        var history_index: ?u32 = null;
        for (self.scope_history.source_owners, 0..) |source_owner, index| if (source_owner.scope == @as(Scope.ScopeId, @fromBackingInt(scope)) and source_owner.owner.node == owner.?.node) {
            if (history_index != null) std.debug.panic("drop scope has duplicate initial owner births", .{});
            history_index = @intCast(index);
        };
        try owners.append(a, .{ .scope = @fromBackingInt(scope), .frame = self.scopes[scope], .owner = owner orelse unreachable, .history_index = history_index });
    }
    var declarations: std.ArrayList(Declaration) = .empty;
    errdefer {
        for (declarations.items) |declaration| a.free(declaration.exposed_bindings);
        declarations.deinit(a);
    }
    var references: std.ArrayList(Symbol.Reference) = .empty;
    errdefer references.deinit(a);
    for (self.references) |row| {
        if (row.flags.declare) {
            const sid = @backingInt(row.symbol_id);
            if (row.declaration_node_index.isNone()) {
                if (sid >= self.symbols.len or self.symbols[sid].synthetic_kind != .implicit_arguments) continue;
                var owned_scope = false;
                for (owners.items) |owner| if (owner.scope == row.scope_id) {
                    owned_scope = true;
                    break;
                };
                if (!owned_scope) continue;
                try declarations.append(a, .{ .before = self.symbols[sid], .row = row, .binding_node = null, .attached_symbol = null });
                continue;
            }
            if (!selected.contains(@backingInt(row.declaration_node_index))) continue;
            if (sid >= self.symbols.len or @backingInt(row.declaration_node_index) >= self.symbol_ids.items.len)
                std.debug.panic("dropped source declaration is outside its original graph", .{});
            const binding_node = self.ast.getNode(row.declaration_node_index);
            const exposed = try captureExposed(self, self.symbols[sid].scope_id, row.symbol_id, self.ast.identifierNameText(binding_node));
            errdefer self.allocator.free(exposed);
            try declarations.append(a, .{ .before = self.symbols[sid], .row = row, .binding_node = binding_node, .attached_symbol = self.symbol_ids.items[@backingInt(row.declaration_node_index)], .exposed_bindings = exposed });
        } else if (!row.node_index.isNone() and selected.contains(@backingInt(row.node_index))) {
            try references.append(a, row);
        }
    }
    var edges: std.ArrayList(Registry.Edge) = .empty;
    errdefer edges.deinit(a);
    for (nodes) |raw| {
        const parent = Registry.Node.captureSource(self.ast, self.symbol_ids.items, @fromBackingInt(raw)) orelse std.debug.panic("drop source has an invalid active payload", .{});
        var count_children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.nodes.items[raw]);
        var count: u32 = 0;
        while (count_children.next() != null) count += 1;
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.nodes.items[raw]);
        var ordinal: u32 = 0;
        while (children.next()) |child| : (ordinal += 1) {
            const snapshot = if (child.isNone()) null else Registry.Node.captureSource(self.ast, self.symbol_ids.items, child) orelse std.debug.panic("drop source child has an invalid active payload", .{});
            try edges.append(a, .{ .parent = parent, .child = snapshot, .ordinal = ordinal, .child_count = count });
        }
    }
    const owned_declarations = try declarations.toOwnedSlice(a);
    errdefer {
        for (owned_declarations) |declaration| a.free(declaration.exposed_bindings);
        a.free(owned_declarations);
    }
    const owned_references = try references.toOwnedSlice(a);
    errdefer a.free(owned_references);
    const owned_owners = try owners.toOwnedSlice(a);
    errdefer a.free(owned_owners);
    const owned_edges = try edges.toOwnedSlice(a);
    return .{
        .statement = statement,
        .statement_node = self.ast.getNode(statement),
        .original = Registry.Node.captureSource(self.ast, self.symbol_ids.items, statement) orelse unreachable,
        .action = switch (self.ast.getNode(statement).tag) {
            .labeled_statement => .label,
            .expression_statement => .console,
            .debugger_statement => .debugger,
            else => unreachable,
        },
        .entry_epoch = @intCast(self.scope_history.events.len),
        .edges = owned_edges,
        .nodes = nodes,
        .declarations = owned_declarations,
        .references = owned_references,
        .owners = owned_owners,
    };
}

pub fn captureInitial(self: anytype) std.mem.Allocator.Error!void {
    if (!self.semantic_edit_enabled or (self.options.drop_labels.len == 0 and !self.options.drop_console and !self.options.drop_debugger)) return;
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, self.ast, @fromBackingInt(self.parser_node_count - 1));
    defer self.allocator.free(nodes);
    for (nodes) |raw| {
        const node = self.ast.nodes.items[raw];
        if (!self.shouldDropNode(node)) continue;
        const source = try capture(self, @fromBackingInt(raw));
        errdefer source.deinit(self.allocator);
        try self.dropped_statement_sources.append(self.allocator, source);
    }
}

pub fn select(self: anytype, editor: anytype, statement: Ast.NodeIndex) std.mem.Allocator.Error!void {
    for (self.dropped_statement_sources.items) |*source| {
        if (source.statement != statement) continue;
        if (source.registry_index != null or self.current_scope.isNone() or self.current_scope.toIndex() >= editor.scopes.items.len)
            std.debug.panic("drop selection lost its actual source scope or ran twice", .{});
        source.registry_index = editor.scope_history.recordDroppedStatement(self.allocator, self.ast, source.original, source.action, source.edges, statement, self.current_scope, editor.scopes.items[self.current_scope.toIndex()], source.entry_epoch) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("drop selection changed its captured source edges", .{}),
        };
        return;
    }
    // A newly generated expression statement can be filtered as well. It has
    // no source declarations to retire; any source-owned output must arrive
    // through its existing explicit copy producer, never a spelling lookup.
    const source = try capture(self, statement);
    defer source.deinit(self.allocator);
    if (source.declarations.len != 0 or source.owners.len != 0)
        std.debug.panic("dropped output lost its actual source statement birth", .{});
}

fn captureExposed(self: anytype, storage: Scope.ScopeId, erased: Symbol.SymbolId, name: []const u8) std.mem.Allocator.Error![]const Symbol.SymbolId {
    var result: std.ArrayList(Symbol.SymbolId) = .empty;
    errdefer result.deinit(self.allocator);
    var scope = self.scopes[storage.toIndex()].parent;
    var fuel = self.scopes.len;
    while (!scope.isNone() and fuel > 0) : (fuel -= 1) {
        if (scope.toIndex() >= self.scopes.len or scope.toIndex() >= self.scope_maps.len) unreachable;
        if (self.scopes[scope.toIndex()].blocksMangling()) break;
        var entries = self.scope_maps[scope.toIndex()].iterator();
        while (entries.next()) |entry| if (@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(entry.key_ptr.*, name)) {
            if (entry.value_ptr.* >= self.symbols.len) unreachable;
            const sid: Symbol.SymbolId = @fromBackingInt(@as(u32, @intCast(entry.value_ptr.*)));
            if (sid != erased) try result.append(self.allocator, sid);
            break;
        };
        scope = self.scopes[scope.toIndex()].parent;
    }
    return result.toOwnedSlice(self.allocator);
}

pub fn consume(self: anytype, editor: anytype, live: *const std.AutoHashMapUnmanaged(u32, void)) !void {
    const Retirement = @import("../semantic/source_owned_retirement.zig");
    const Choice = struct { source: usize, declaration: usize };
    var bindings: std.AutoHashMapUnmanaged(u32, Choice) = .empty;
    defer bindings.deinit(self.allocator);
    // Remove precisely the source declaration rows belonging to selected drops.
    for (self.dropped_statement_sources.items, 0..) |source, source_index| {
        if (source.registry_index == null) continue;
        if (live.contains(@backingInt(source.statement))) return error.InvalidNode;
        for (source.declarations, 0..) |declaration, declaration_index| {
            const row = declaration.row;
            const sid = @backingInt(row.symbol_id);
            if (sid >= editor.symbols.items.len) return error.InvalidSymbol;
            const anchor = row.declaration_node_index;
            if (!anchor.isNone() and live.contains(@backingInt(anchor))) continue;
            var removed: usize = 0;
            var write: usize = 0;
            for (editor.references.items) |current| {
                if (current.symbol_id == row.symbol_id and current.flags.declare and current.declaration_node_index == anchor) {
                    if (current.scope_id != row.scope_id or current.node_index != row.node_index or !std.meta.eql(current.flags, row.flags)) return error.InvalidSymbol;
                    removed += 1;
                    continue;
                }
                editor.references.items[write] = current;
                write += 1;
            }
            if (removed != 1) return error.ReferenceNotFound;
            editor.references.shrinkRetainingCapacity(write);
            editor.reference_index.clearRetainingCapacity();
            editor.reference_index_built = false;
            if (!anchor.isNone()) {
                if (declaration.attached_symbol != sid or @backingInt(anchor) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(anchor)] != sid) return error.InvalidSymbol;
                editor.symbol_ids.items[@backingInt(anchor)] = null;
                self.symbol_ids.items[@backingInt(anchor)] = null;
            }
            const candidate = try bindings.getOrPut(self.allocator, sid);
            const primary = declaration.binding_node != null and std.meta.eql(declaration.binding_node.?.span, declaration.before.name) and
                declaration.before.declaration_span.start >= source.statement_node.span.start and declaration.before.declaration_span.end <= source.statement_node.span.end;
            if (!candidate.found_existing or primary) candidate.value_ptr.* = .{ .source = source_index, .declaration = declaration_index };
        }
    }
    var values = bindings.iterator();
    while (values.next()) |entry| {
        const sid = entry.key_ptr.*;
        const source = self.dropped_statement_sources.items[entry.value_ptr.source];
        const declaration = source.declarations[entry.value_ptr.declaration];
        var remaining_declaration = false;
        for (editor.references.items) |row| if (@backingInt(row.symbol_id) == sid and row.flags.declare) {
            remaining_declaration = true;
            break;
        };
        if (remaining_declaration) continue;
        var target: ?Symbol.SymbolId = null;
        for (declaration.exposed_bindings) |candidate| {
            if (editor.source_owned_retirements.contains(@backingInt(candidate))) continue;
            if (@backingInt(candidate) >= editor.symbols.items.len) return error.InvalidSymbol;
            target = candidate;
            break;
        }
        try detachLiveUses(self, editor, live, declaration.row.symbol_id, target);
        var expected = declaration.before;
        expected.reference_count = 0;
        expected.write_count = 0;
        if (!Retirement.equalSymbol(expected, editor.symbols.items[sid])) return error.InvalidSymbol;
        for (editor.scope_maps.items) |*map| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.allocator);
            var entries = map.iterator();
            while (entries.next()) |binding| if (binding.value_ptr.* == sid) try keys.append(self.allocator, binding.key_ptr.*);
            for (keys.items) |key| _ = map.remove(key);
        }
        var scope_owner: ?u32 = null;
        for (source.owners) |owner| if (owner.scope == declaration.before.scope_id) {
            scope_owner = owner.history_index orelse return error.InvalidScope;
            break;
        };
        if (editor.source_owned_retirements.contains(sid)) return error.InvalidSymbol;
        try editor.source_owned_retirements.put(self.allocator, sid, .{
            .symbol_id = declaration.row.symbol_id,
            .before = declaration.before,
            .declaration = declaration.row,
            .declaration_node = declaration.binding_node,
            .source_owner = source.statement,
            .source_owner_node = source.statement_node,
            .source_scope = declaration.before.scope_id,
            .source_parent = self.scopes[declaration.before.scope_id.toIndex()].parent,
            .source_name = declaration.row.declaration_node_index,
            .source_name_symbol = if (declaration.binding_node != null) declaration.row.symbol_id else .none,
            .closure_scope = if (scope_owner != null) declaration.before.scope_id else .none,
            .closure_parent = if (scope_owner != null) self.scopes[declaration.before.scope_id.toIndex()].parent else .none,
            .reason = .dropped_statement,
            .dropped_statement = .{ .statement = source.registry_index.?, .scope_owner = scope_owner },
        });
    }
    // Empty source blocks/functions have owners even when they own no slots.
    for (self.dropped_statement_sources.items) |source| {
        if (source.registry_index == null) continue;
        for (source.owners) |owner| {
            if (live.contains(@backingInt(owner.owner.node))) continue;
            if (editor.scope_owner_map.get(@backingInt(owner.owner.node))) |scope| {
                if (scope != @backingInt(owner.scope) or editor.scope_maps.items[scope].count() != 0) return error.InvalidScope;
                _ = try editor.removeScopeOwner(owner.owner.node);
            }
        }
    }
}

fn detachLiveUses(self: anytype, editor: anytype, live: *const std.AutoHashMapUnmanaged(u32, void), sid: Symbol.SymbolId, target: ?Symbol.SymbolId) !void {
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(self.allocator);
    var parents_ready = false;
    var index = editor.references.items.len;
    while (index > 0) {
        index -= 1;
        const row = editor.references.items[index];
        if (row.symbol_id != sid or row.flags.declare or row.node_index.isNone()) continue;
        const raw = @backingInt(row.node_index);
        if (!live.contains(raw) or raw >= editor.symbol_ids.items.len or editor.symbol_ids.items[raw] != @backingInt(sid)) return error.InvalidSymbol;
        if (target) |binding| {
            try editor.rebindReference(row.node_index, binding);
            self.symbol_ids.items[raw] = @backingInt(binding);
            continue;
        }
        const node = self.ast.getNode(row.node_index);
        switch (node.tag) {
            .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
            else => return error.InvalidNode,
        }
        if (!parents_ready) {
            var nodes = live.keyIterator();
            while (nodes.next()) |parent| {
                var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.nodes.items[parent.*]);
                while (children.next()) |child| {
                    if (child.isNone()) continue;
                    const entry = try parents.getOrPut(self.allocator, @backingInt(child));
                    if (entry.found_existing and entry.value_ptr.* != parent.*) return error.InvalidNode;
                    entry.value_ptr.* = parent.*;
                }
            }
            parents_ready = true;
        }
        var in_with = false;
        var child = raw;
        var fuel = self.ast.nodes.items.len;
        while (parents.get(child)) |parent| : (fuel -= 1) {
            if (fuel == 0) return error.InvalidNode;
            const ancestor = self.ast.nodes.items[parent];
            if (ancestor.tag == .with_statement and @backingInt(ancestor.data.binary.right) == child) in_with = true;
            child = parent;
        }
        if (editor.node_scope_provenance.get(row.node_index)) |before| if (before.source_external != null or before.external_import != null or before.scope != row.scope_id) return error.InvalidSymbol;
        try editor.node_scope_provenance.put(self.allocator, row.node_index, .{
            .scope = row.scope_id,
            .source_node = row.node_index,
            .with_environment = in_with,
            .external_import = .{ .binding_symbol = sid, .before = row, .before_tag = node.tag, .before_name = node.data.string_ref, .before_span = node.span },
        });
        try editor.removeReference(row.node_index);
        self.symbol_ids.items[raw] = null;
    }
}

test "explicit statement drop retirement keeps source proofs across codec and heap capture OOM" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Data = @import("../bundler/module.zig").ModuleSemanticData;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "let outside=40;DEV:{const hidden=2;}DEV:{const hidden=3;}console.log(outside+2);";
    var scanner = try Scanner.init(a, text);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const count: u32 = @intCast(parser.ast.nodes.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_source_external_origins = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var transformer = try @import("transformer.zig").Transformer.initFromOwnedAst(a, &parser.ast, .{ .drop_labels = &.{"DEV"} });
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
    var selected: ?Ast.NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .labeled_statement) {
        selected = @fromBackingInt(@as(u32, @intCast(raw)));
        break;
    };
    const source_statement = selected orelse return error.MissingSourceStatement;
    const original_nodes = try a.dupe(u8, std.mem.sliceAsBytes(parser.ast.nodes.items));
    const original_ids = try a.dupe(u8, std.mem.sliceAsBytes(transformer.symbol_ids.items));
    const original_symbols = try a.dupe(u8, std.mem.sliceAsBytes(analyzer.symbols.items));
    const original_rows = try a.dupe(u8, std.mem.sliceAsBytes(analyzer.references.items));
    var failures: usize = 0;
    var success = false;
    for (0..128) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = offset });
        transformer.allocator = failing.allocator();
        defer transformer.allocator = a;
        const source = capture(&transformer, source_statement) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expectEqualSlices(u8, original_nodes, std.mem.sliceAsBytes(parser.ast.nodes.items));
            try std.testing.expectEqualSlices(u8, original_ids, std.mem.sliceAsBytes(transformer.symbol_ids.items));
            try std.testing.expectEqualSlices(u8, original_symbols, std.mem.sliceAsBytes(analyzer.symbols.items));
            try std.testing.expectEqualSlices(u8, original_rows, std.mem.sliceAsBytes(analyzer.references.items));
            continue;
        };
        source.deinit(failing.allocator());
        success = true;
        break;
    }
    try std.testing.expect(failures > 0 and success);
    std.debug.print("DROP_CAPTURE_HEAP_OOM failures={d} success={}\n", .{ failures, success });
    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var data: Data = .{ .symbols = edited.symbols, .scopes = edited.scopes, .scope_maps = edited.scope_maps, .scope_owner_map = edited.scope_owner_map, .symbol_ids = edited.symbol_ids, .references = edited.references, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .helper_scope_map = edited.helper_scope_map, .node_scope_provenance = edited.node_scope_provenance, .scope_history = edited.scope_history, .source_owned_retirements = edited.source_owned_retirements };
    const Check = struct {
        fn run(alloc: std.mem.Allocator, tree: *const Ast.Ast, output: Ast.NodeIndex, parser_count: u32, sem: *const Data, unresolved: *const std.AutoHashMapUnmanaged(u32, void), producer: anytype) !bool {
            var report = try @import("symbol_coverage.zig").checkOutputNormalFormQuiet(alloc, tree, output, parser_count, sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, producer.helper_ref_nodes.items, &sem.helper_scope_map, unresolved, &producer.explicit_global_reference_nodes, &producer.reference_origin_map, .{ .pre_transform_scope_count = sem.scope_history.source_scopes.len }, &sem.source_owned_retirements, .{ .node_scope_provenance = &sem.node_scope_provenance, .scope_history = &sem.scope_history, .runtime_helper_symbols = &producer.runtime_helper_symbol_ids, .class_self_symbols = &producer.class_self_symbol_map });
            defer report.deinit(alloc);
            return report.hasCompleteOutputIdentityBeforeNames();
        }
    };
    try std.testing.expectEqual(@as(u32, 2), data.source_owned_retirements.count());
    try std.testing.expectEqual(@as(usize, 2), data.scope_history.source_dropped_statements.len);
    try std.testing.expect(try Check.run(a, transformer.ast, root, count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    var entries = data.source_owned_retirements.iterator();
    const first = entries.next() orelse return error.MissingRetirement;
    const sid = first.key_ptr.*;
    const original = first.value_ptr.*;
    const raw_binding = @backingInt(original.source_name);
    const statement_index = original.dropped_statement.?.statement;
    for (0..8) |poison| {
        var wrong = original;
        switch (poison) {
            0 => wrong.dropped_statement = null,
            1 => wrong.dropped_statement.?.statement = @intCast(data.scope_history.source_dropped_statements.len),
            2 => wrong.source_scope = .none,
            3 => wrong.before.origin_scope = .none,
            4 => wrong.source_name_symbol = .none,
            5 => wrong.dropped_statement.?.scope_owner = null,
            6 => wrong.source_owner_node.span.end += 1,
            7 => wrong.declaration.symbol_id = .none,
            else => unreachable,
        }
        first.value_ptr.* = wrong;
        try std.testing.expect(!try Check.run(a, transformer.ast, root, count, &data, &analyzer.unresolved_reference_nodes, &transformer));
        first.value_ptr.* = original;
    }
    @constCast(data.symbol_ids)[raw_binding] = sid;
    try std.testing.expect(!try Check.run(a, transformer.ast, root, count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    @constCast(data.symbol_ids)[raw_binding] = null;
    const snapshots = @constCast(data.scope_history.source_drop_edges);
    var poisoned_edge: ?usize = null;
    for (snapshots, 0..) |edge, index| if (edge.child) |child| if (child.index == original.source_name) {
        poisoned_edge = index;
        break;
    };
    const edge_index = poisoned_edge orelse return error.MissingBindingBirth;
    const before_edge = snapshots[edge_index];
    snapshots[edge_index].child.?.source_symbol = null;
    try std.testing.expect(!try Check.run(a, transformer.ast, root, count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    snapshots[edge_index] = before_edge;
    const roots = @constCast(data.scope_history.source_dropped_statements);
    const before_root = roots[statement_index];
    const before_node = transformer.ast.getNode(original.source_owner);
    transformer.ast.nodes.items[@backingInt(original.source_owner)].span.end += 1;
    roots[statement_index].selected = Registry.Node.capture(transformer.ast, original.source_owner).?;
    try std.testing.expect(!try Check.run(a, transformer.ast, root, count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    transformer.ast.nodes.items[@backingInt(original.source_owner)] = before_node;
    roots[statement_index] = before_root;
    try std.testing.expect(try Check.run(a, transformer.ast, root, count, &data, &analyzer.unresolved_reference_nodes, &transformer));
    var encoded: std.ArrayList(u8) = .empty;
    try @import("../bundler/semantic_codec.zig").serialize(&data, &encoded, a);
    var decoded = try @import("../bundler/semantic_codec.zig").deserialize(encoded.items, a);
    try std.testing.expectEqual(@as(u32, 2), decoded.source_owned_retirements.count());
    try std.testing.expect(try Check.run(a, transformer.ast, root, count, &decoded, &analyzer.unresolved_reference_nodes, &transformer));
}
