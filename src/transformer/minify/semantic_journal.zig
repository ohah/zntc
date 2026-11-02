//! Exact producer events for in-place syntax minification. No spelling lookup,
//! binding resolution, or replacement SymbolId allocation happens here.
const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const symbol_mod = @import("../../semantic/symbol.zig");
const Reference = symbol_mod.Reference;
const Scope = @import("../../semantic/scope.zig").Scope;
const SemanticEditor = @import("../../semantic/editor.zig").SemanticEditor;
const reference_walk = @import("../../semantic/reference_walk.zig");
const NodeProvenance = @import("../../semantic/node_scope_provenance.zig");
const RetirementReceipt = @import("../../semantic/function_retirement_receipt.zig");
const InlineBinding = @import("../../semantic/inlined_binding_retirement.zig");
const statement_coordinates = @import("../../semantic/statement_coordinates.zig");

pub const SemanticJournal = struct {
    pub const Error = std.mem.Allocator.Error || error{ InvalidReferenceIdentity, ScopeOwnerConflict };
    pub const BaselineEdge = struct {
        reference: Reference,
        node: ast_mod.Node,
        attached_symbol: ?u32,
        reason: enum { absent_runtime_edge, replaced_symbol },
    };
    pub const IdentityMaps = struct {
        domain: *const ast_mod.Ast,
        root: ast_mod.NodeIndex,
        symbol_ids: []const ?u32,
        owners: *const std.AutoHashMapUnmanaged(u32, u32),
        expressions: *const NodeProvenance.Map,
        class_self: *const std.AutoHashMapUnmanaged(u32, u32),
        symbols: []const symbol_mod.Symbol,
        scopes: []const Scope,
        scope_maps: []const std.StringHashMapUnmanaged(usize),
        source_epoch: u32 = 0,
    };
    pub const Event = struct {
        source: u32,
        target: u32,
        source_owner: ?u32,
        target_owner: ?u32,
        source_expression: ?NodeProvenance.Entry,
        source_class_self: ?u32,
        inline_scope: ?SemanticEditor.EmptyArrowScopeElision = null,
        source_payload: ast_mod.Node,
        target_payload: ast_mod.Node,
        source_reference: ?Reference,
    };
    allocator: std.mem.Allocator,
    domain: *const ast_mod.Ast,
    source_references: []Reference = &.{},
    source_expressions: NodeProvenance.Map = .empty,
    baseline_edges: std.ArrayList(BaselineEdge) = .empty,
    events: std.ArrayList(Event) = .empty,
    function_name_elisions: std.ArrayList(@import("../../semantic/function_name_retirement.zig").Elision) = .empty,
    references: std.AutoHashMapUnmanaged(u32, Reference) = .empty,
    targets: std.AutoHashMapUnmanaged(u32, void) = .empty,
    inlined_bindings: std.ArrayList(InlineBinding.Event) = .empty,
    baseline_scopes: []const Scope = &.{},
    source_epoch: u32 = 0,
    failure: ?Error = null,
    owners: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    expressions: NodeProvenance.Map = .empty,
    class_self: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    symbols: []const symbol_mod.Symbol = &.{},
    scope_maps: []const std.StringHashMapUnmanaged(usize) = &.{},

    pub fn init(allocator: std.mem.Allocator, references: []const Reference, maps: IdentityMaps) Error!SemanticJournal {
        var self: SemanticJournal = .{ .allocator = allocator, .domain = maps.domain };
        errdefer self.deinit();
        self.source_references = try allocator.dupe(Reference, references);
        self.source_expressions = try maps.expressions.clone(allocator);
        const runtime_nodes = try reference_walk.collectIdentifierReferences(allocator, maps.domain, maps.root);
        defer allocator.free(runtime_nodes);
        var runtime: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer runtime.deinit(allocator);
        for (runtime_nodes) |node| try runtime.put(allocator, @backingInt(node), {});
        for (references) |reference| {
            if (reference.flags.declare or reference.node_index.isNone()) continue;
            const raw = @backingInt(reference.node_index);
            if (raw >= maps.domain.nodes.items.len or raw >= maps.symbol_ids.len) return error.InvalidReferenceIdentity;
            const attached = maps.symbol_ids[raw];
            if (!runtime.contains(raw) or attached != @as(?u32, @backingInt(reference.symbol_id))) {
                if (!reference.flags.type_context and !reference.flags.value_as_type) try self.baseline_edges.append(allocator, .{
                    .reference = reference,
                    .node = maps.domain.nodes.items[raw],
                    .attached_symbol = attached,
                    .reason = if (!runtime.contains(raw)) .absent_runtime_edge else .replaced_symbol,
                });
                continue;
            }
            const entry = try self.references.getOrPut(allocator, raw);
            if (entry.found_existing) return error.InvalidReferenceIdentity;
            entry.value_ptr.* = reference;
        }
        self.owners = try maps.owners.clone(allocator);
        self.expressions = try maps.expressions.clone(allocator);
        self.class_self = try maps.class_self.clone(allocator);
        try self.scopes.appendSlice(allocator, maps.scopes);
        self.baseline_scopes = maps.scopes;
        self.source_epoch = maps.source_epoch;
        self.symbols = maps.symbols;
        self.scope_maps = maps.scope_maps;
        return self;
    }

    pub fn deinit(self: *SemanticJournal) void {
        self.inlined_bindings.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.function_name_elisions.deinit(self.allocator);
        self.allocator.free(self.source_references);
        self.source_expressions.deinit(self.allocator);
        self.baseline_edges.deinit(self.allocator);
        self.references.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        self.owners.deinit(self.allocator);
        self.expressions.deinit(self.allocator);
        self.class_self.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
    }

    /// Actual name-slot producer event, captured before the slot is cleared.
    pub fn recordFunctionNameElision(self: *SemanticJournal, ast: *const ast_mod.Ast, owner: u32, ids: []const ?u32) bool {
        if (self.failure != null) return false;
        if (ast != self.domain or owner >= ast.nodes.items.len) {
            self.failure = error.InvalidReferenceIdentity;
            return false;
        }
        const node = ast.nodes.items[owner];
        if (node.tag != .function_expression or !ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.flags)) {
            self.failure = error.InvalidReferenceIdentity;
            return false;
        }
        const name = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (name.isNone() or @backingInt(name) >= ids.len or ids[@backingInt(name)] == null) {
            self.failure = error.InvalidReferenceIdentity;
            return false;
        }
        self.function_name_elisions.append(self.allocator, .{ .owner = @fromBackingInt(owner), .owner_node = node, .name = name, .name_node = ast.getNode(name), .symbol_id = @fromBackingInt(ids[@backingInt(name)].?), .parameters = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params), .body = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.body) }) catch |err| {
            self.failure = err;
            return false;
        };
        return true;
    }

    /// Capture only the declaration selected by tryInlineDecl, before either
    /// the read or statement is overwritten. Later cleanup consumes this tuple.
    pub fn recordInlinedLocalBinding(self: *SemanticJournal, ast: *const ast_mod.Ast, statement: u32, declarator: u32, binding: u32, initializer: u32, read: u32, sid: u32, wrapped: bool, ids: []const ?u32) bool {
        if (self.failure != null) return false;
        self.captureInlinedLocalBinding(ast, statement, declarator, binding, initializer, read, sid, wrapped, ids) catch |err| {
            self.failure = err;
            return false;
        };
        return true;
    }

    fn captureInlinedLocalBinding(self: *SemanticJournal, ast: *const ast_mod.Ast, statement: u32, declarator: u32, binding: u32, initializer: u32, read: u32, sid: u32, wrapped: bool, ids: []const ?u32) Error!void {
        if (ast != self.domain or sid >= self.symbols.len) return error.InvalidReferenceIdentity;
        for ([_]u32{ statement, declarator, binding, initializer, read }) |raw| if (raw >= ast.nodes.items.len) return error.InvalidReferenceIdentity;
        if (binding >= ids.len or ids[binding] != sid or read >= ids.len or ids[read] != sid) return error.InvalidReferenceIdentity;
        const before = self.symbols[sid];
        if ((before.kind != .variable_let and before.kind != .variable_const) or before.isExported() or before.write_count != 0 or before.scope_id.isNone() or before.scope_id.toIndex() >= self.baseline_scopes.len) return error.InvalidReferenceIdentity;
        const actual_read = self.references.get(read) orelse return error.InvalidReferenceIdentity;
        if (@backingInt(actual_read.symbol_id) != sid or !actual_read.flags.read or actual_read.flags.write or actual_read.flags.declare or actual_read.scope_id.isNone() or actual_read.scope_id.toIndex() >= self.baseline_scopes.len or ast.nodes.items[read].tag != .identifier_reference) return error.InvalidReferenceIdentity;
        var declaration: ?Reference = null;
        for (self.source_references) |row| {
            if (@backingInt(row.symbol_id) != sid or !row.flags.declare) continue;
            if (declaration != null or !row.node_index.isNone() or @backingInt(row.declaration_node_index) != binding or row.scope_id != before.scope_id or !std.meta.eql(row.flags, @as(symbol_mod.ReferenceFlags, .{ .declare = true }))) return error.InvalidReferenceIdentity;
            declaration = row;
        }
        const source_statement = ast.nodes.items[statement];
        if (source_statement.tag != .variable_declaration or ast.nodes.items[declarator].tag != .variable_declarator or ast.nodes.items[binding].tag != .binding_identifier or !ast.hasExtra(source_statement.data.extra, 2)) return error.InvalidReferenceIdentity;
        try self.inlined_bindings.append(self.allocator, .{
            .domain = ast,
            .symbol_id = @fromBackingInt(sid),
            .before = before,
            .statement = @fromBackingInt(statement),
            .statement_node = source_statement,
            .declaration = declaration orelse return error.InvalidReferenceIdentity,
            .binding = @fromBackingInt(binding),
            .binding_node = ast.nodes.items[binding],
            .initializer_node = ast.nodes.items[initializer],
            .wrapped_initializer = wrapped,
            .witness = .{
                .declarator = @fromBackingInt(declarator),
                .declarator_node = ast.nodes.items[declarator],
                .initializer = @fromBackingInt(initializer),
                .read = @fromBackingInt(read),
                .read_node = ast.nodes.items[read],
                .read_reference = actual_read,
                .statement_kind = ast.extra_data.items[source_statement.data.extra],
                .source_epoch = self.source_epoch,
                .source_frame = self.baseline_scopes[before.scope_id.toIndex()],
                .read_frame = self.baseline_scopes[actual_read.scope_id.toIndex()],
            },
        });
    }

    /// Called before the AST and its attached ID are overwritten. The map is
    /// updated in event order, so later copies can use an earlier target.
    /// Minify's existing void API records failure; the owner must call apply
    /// and propagate it before publishing candidate AST/graph/output.
    pub fn recordCopy(self: *SemanticJournal, ast: *const ast_mod.Ast, source: u32, target: u32, ids: []const ?u32) void {
        if (self.failure != null) return;
        if (ast != self.domain) {
            self.failure = error.InvalidReferenceIdentity;
            return;
        }
        if (source == target) return;
        self.recordCopyFallible(ast, source, target, ids) catch |err| {
            self.failure = err;
        };
    }

    fn recordCopyFallible(self: *SemanticJournal, ast: *const ast_mod.Ast, source: u32, target: u32, ids: []const ?u32) Error!void {
        if (source >= ast.nodes.items.len or target >= ast.nodes.items.len or source >= ids.len or target >= ids.len)
            return error.InvalidReferenceIdentity;
        const node = ast.nodes.items[source];
        const is_reference = node.tag == .identifier_reference or node.tag == .assignment_target_identifier or node.tag == .jsx_identifier;
        const source_reference = if (is_reference) self.references.get(source) else null;
        var next: ?Reference = null;
        if (is_reference) {
            if (ids[source]) |id| {
                var reference = self.references.get(source) orelse return error.InvalidReferenceIdentity;
                if (@backingInt(reference.symbol_id) != id) return error.InvalidReferenceIdentity;
                // Alias inlining keeps the target read's statement location.
                // A parent expression without a row inherits its child location.
                if (self.references.get(target)) |previous| {
                    reference.scope_id = previous.scope_id;
                    reference.stmt_idx = previous.stmt_idx;
                    reference.scope_stmt_idx = previous.scope_stmt_idx;
                }
                reference.node_index = @fromBackingInt(target);
                next = reference;
            } else if (self.references.contains(source)) return error.InvalidReferenceIdentity;
        }
        const source_owner = self.owners.get(source);
        const target_owner = self.owners.get(target);
        if (target_owner != null and target_owner != source_owner) return error.ScopeOwnerConflict;
        const source_expression = self.expressions.get(@fromBackingInt(source));
        const source_class_self = self.class_self.get(source);
        try self.events.append(self.allocator, .{ .source = source, .target = target, .source_owner = source_owner, .target_owner = target_owner, .source_expression = source_expression, .source_class_self = source_class_self, .source_payload = node, .target_payload = ast.nodes.items[target], .source_reference = source_reference });
        if (source_owner) |owner| try self.owners.put(self.allocator, target, owner) else _ = self.owners.remove(target);
        if (source_expression) |entry| try self.expressions.put(self.allocator, @fromBackingInt(target), entry) else _ = self.expressions.remove(@fromBackingInt(target));
        if (source_class_self) |id| try self.class_self.put(self.allocator, target, id) else _ = self.class_self.remove(target);
        try self.targets.put(self.allocator, target, {});
        if (next) |reference| try self.references.put(self.allocator, target, reference) else _ = self.references.remove(target);
    }

    /// A parameterless, synchronous, non-dynamic arrow with no own binding
    /// can disappear while preserving its inherited lexical environment.
    /// Failure to prove this is an optional-optimization refusal, not an error.
    pub fn recordInlineArrow(self: *SemanticJournal, ast: *const ast_mod.Ast, owner: u32, target: u32) bool {
        if (self.failure != null) return false;
        if (ast != self.domain) {
            self.failure = error.InvalidReferenceIdentity;
            return false;
        }
        const scope = self.owners.get(owner) orelse return false;
        if (scope >= self.scopes.items.len or scope >= self.scope_maps.len or owner >= ast.nodes.items.len) return false;
        const source = ast.nodes.items[owner];
        if (source.tag != .arrow_function_expression or ast.functionParams(source).len != 0 or
            !ast.hasExtra(source.data.extra, ast_mod.ArrowExtra.flags) or
            ast.readExtra(source.data.extra, ast_mod.ArrowExtra.flags) & ast_mod.ArrowFlags.is_async != 0) return false;
        const frame = self.scopes.items[scope];
        if (frame.parent.isNone() or frame.parent.toIndex() >= self.scopes.items.len or
            frame.kind != .function or frame.blocksMangling() or frame.symbol_count != 0 or
            self.scope_maps[scope].count() != 0 or
            frame.is_strict != self.scopes.items[frame.parent.toIndex()].is_strict) return false;
        for (self.symbols) |symbol| if (symbol.scope_id.toIndex() == scope) return false;
        var references = self.references.valueIterator();
        while (references.next()) |reference| {
            if (reference.scope_id.toIndex() != scope) continue;
            if (@backingInt(reference.symbol_id) >= self.symbols.len) return false;
            const binding_scope = self.symbols[@backingInt(reference.symbol_id)].scope_id;
            var cursor = frame.parent;
            var visible = false;
            var hops: usize = 0;
            while (!cursor.isNone() and cursor.toIndex() < self.scopes.items.len and hops < self.scopes.items.len) : (hops += 1) {
                if (cursor == binding_scope) {
                    visible = true;
                    break;
                }
                cursor = self.scopes.items[cursor.toIndex()].parent;
            }
            if (!visible) return false;
        }
        const plan: SemanticEditor.EmptyArrowScopeElision = .{ .owner = @fromBackingInt(owner), .scope = @fromBackingInt(scope), .parent = frame.parent, .source = source };
        self.events.append(self.allocator, .{ .source = owner, .target = target, .source_owner = scope, .target_owner = null, .source_expression = null, .source_class_self = null, .inline_scope = plan, .source_payload = source, .target_payload = ast.nodes.items[target], .source_reference = null }) catch |err| {
            self.failure = err;
            return false;
        };
        _ = self.owners.remove(owner);
        for (self.scopes.items) |*child| if (child.parent.toIndex() == scope) {
            child.parent = frame.parent;
        };
        references = self.references.valueIterator();
        while (references.next()) |reference| if (reference.scope_id.toIndex() == scope) {
            reference.scope_id = frame.parent;
        };
        var expressions = self.expressions.valueIterator();
        while (expressions.next()) |entry| if (entry.scope.toIndex() == scope) {
            entry.scope = frame.parent;
        };
        return true;
    }

    /// Drain into the caller's candidate editor. Original inputs remain owned
    /// by the caller. A failure must discard this candidate, never reanalyze it.
    pub fn apply(self: *const SemanticJournal, editor: *SemanticEditor, root: ast_mod.NodeIndex, origins: ?*std.AutoHashMapUnmanaged(u32, u32), class_self: ?*std.AutoHashMapUnmanaged(u32, u32)) !void {
        const receipt = try self.applyReferenceAndOwnerEdits(editor, root, origins, class_self);
        defer self.freeApplicationReceipt(receipt);
        try self.retireInlinedBindings(editor, root, receipt);
        try self.retireDeadDeclarationAnchors(editor, root);
    }

    /// Phase 1 leaves every declaration row intact. A source-owned function
    /// consumer must run between this phase and generic declaration retirement.
    pub fn applyReferenceAndOwnerEdits(self: *const SemanticJournal, editor: *SemanticEditor, root: ast_mod.NodeIndex, origins: ?*std.AutoHashMapUnmanaged(u32, u32), class_self: ?*std.AutoHashMapUnmanaged(u32, u32)) !RetirementReceipt.ApplicationReceipt {
        if (self.failure) |err| return err;
        if (editor.ast != self.domain or editor.references.items.len != self.source_references.len) return error.InvalidReferenceIdentity;
        for (editor.references.items, self.source_references) |current, source| {
            if (!std.meta.eql(current, source)) return error.InvalidReferenceIdentity;
        }
        const ast = editor.ast;
        const nodes = try reference_walk.collectIdentifierReferences(self.allocator, ast, root);
        defer self.allocator.free(nodes);
        var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer live.deinit(self.allocator);
        for (nodes) |node| try live.put(self.allocator, @backingInt(node), {});
        var index = editor.references.items.len;
        while (index > 0) {
            index -= 1;
            const reference = editor.references.items[index];
            if (reference.flags.declare or reference.node_index.isNone()) continue;
            const raw = @backingInt(reference.node_index);
            if (!live.contains(raw) or self.targets.contains(raw) or raw >= editor.symbol_ids.items.len or
                editor.symbol_ids.items[raw] != @as(?u32, @backingInt(reference.symbol_id))) try editor.removeReference(reference.node_index);
        }
        var targets = self.targets.keyIterator();
        while (targets.next()) |target| {
            if (!live.contains(target.*)) continue;
            if (self.references.get(target.*)) |reference| {
                try editor.addCopiedReference(@fromBackingInt(target.*), reference.symbol_id, reference.scope_id, reference.flags, reference.stmt_idx, reference.scope_stmt_idx);
            }
        }
        if (origins) |map| for (self.events.items) |event| {
            const origin = map.get(event.source) orelse event.source;
            if (event.target != origin) try map.put(self.allocator, event.target, origin) else _ = map.remove(event.target);
        };
        const reachable_nodes = try @import("../../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, ast, root);
        defer self.allocator.free(reachable_nodes);
        var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer reachable.deinit(self.allocator);
        for (reachable_nodes) |raw| try reachable.put(self.allocator, raw, {});
        for (self.events.items) |event| {
            if (event.inline_scope) |plan| {
                try editor.elideEmptyArrowScopeOwner(plan);
                continue;
            }
            const source_node: ast_mod.NodeIndex = @fromBackingInt(event.source);
            const target_node: ast_mod.NodeIndex = @fromBackingInt(event.target);
            if (event.source_owner) |owner| {
                if (editor.scope_owner_map.get(event.source) != owner) return error.ScopeOwnerConflict;
                if (reachable.contains(event.source)) {
                    if (@import("builtin").is_test) std.debug.print("R1_OWNER_ALIAS source={d}:{s} target={d}:{s} owner={d} program={s}\n", .{ event.source, @tagName(ast.nodes.items[event.source].tag), event.target, @tagName(ast.nodes.items[event.target].tag), owner, ast.source });
                    return error.ScopeOwnerConflict;
                }
                try editor.remapScopeOwnerAfterInPlaceRewrite(source_node, target_node);
            }
            if (event.source_expression) |entry| {
                if (editor.node_scope_provenance.get(target_node)) |existing| {
                    if (!std.meta.eql(existing, entry)) return error.InvalidReferenceIdentity;
                } else try editor.node_scope_provenance.put(self.allocator, target_node, entry);
            } else _ = editor.node_scope_provenance.remove(target_node);
            if (!reachable.contains(event.source)) _ = editor.node_scope_provenance.remove(source_node);
            if (class_self) |map| {
                if (event.source_class_self) |id| {
                    if (map.get(event.target)) |existing| {
                        if (existing != id) return error.InvalidReferenceIdentity;
                    } else try map.put(self.allocator, event.target, id);
                } else _ = map.remove(event.target);
                if (!reachable.contains(event.source)) _ = map.remove(event.source);
            } else if (event.source_class_self != null) return error.InvalidReferenceIdentity;
        }
        const positions = try statement_coordinates.collect(self.allocator, ast, root);
        defer self.allocator.free(positions);
        for (editor.references.items) |reference| {
            if (reference.flags.declare or reference.node_index.isNone()) continue;
            const raw = @backingInt(reference.node_index);
            if (raw >= positions.len) return error.InvalidReferenceIdentity;
            const position = positions[raw] orelse return error.InvalidReferenceIdentity;
            try editor.moveReference(reference.node_index, reference.scope_id, position.stmt_idx, position.scope_stmt_idx);
        }
        // Remove only actual dead expression entries, retaining their immutable
        // before tuples in the receipt for the source-owned closure consumer.
        var stale_provenance: std.ArrayList(ast_mod.NodeIndex) = .empty;
        defer stale_provenance.deinit(self.allocator);
        var provenance_nodes = editor.node_scope_provenance.keyIterator();
        while (provenance_nodes.next()) |node| if (!reachable.contains(@backingInt(node.*))) try stale_provenance.append(self.allocator, node.*);
        for (stale_provenance.items) |node| _ = editor.node_scope_provenance.remove(node);
        var reference_changes: std.ArrayList(RetirementReceipt.ReferenceChange) = .empty;
        defer reference_changes.deinit(self.allocator);
        for (self.source_references) |before| {
            if (before.flags.declare or before.node_index.isNone()) continue;
            const after = try editor.referenceForNode(before.node_index);
            if (after == null or !std.meta.eql(before, after.?)) try reference_changes.append(self.allocator, .{ .before = before, .after = after });
        }
        var source_nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer source_nodes.deinit(self.allocator);
        for (self.source_references) |row| if (!row.flags.declare and !row.node_index.isNone()) try source_nodes.put(self.allocator, @backingInt(row.node_index), {});
        for (editor.references.items) |after| {
            if (after.flags.declare or after.node_index.isNone() or source_nodes.contains(@backingInt(after.node_index))) continue;
            try reference_changes.append(self.allocator, .{ .before = null, .after = after });
        }
        var owner_changes: std.ArrayList(RetirementReceipt.OwnerChange) = .empty;
        defer owner_changes.deinit(self.allocator);
        var copies: std.ArrayList(RetirementReceipt.Copy) = .empty;
        defer copies.deinit(self.allocator);
        for (self.events.items) |event| {
            if (event.inline_scope) |plan| {
                try owner_changes.append(self.allocator, .{ .source_owner = plan.owner, .scope = plan.scope, .target_owner = null, .effect = .empty_arrow_elide, .parent = plan.parent });
            } else {
                if (event.source_owner) |scope| try owner_changes.append(self.allocator, .{ .source_owner = @fromBackingInt(event.source), .scope = @fromBackingInt(scope), .target_owner = @as(ast_mod.NodeIndex, @fromBackingInt(event.target)), .effect = .move, .parent = null });
                try copies.append(self.allocator, .{
                    .source = @fromBackingInt(event.source),
                    .target = @fromBackingInt(event.target),
                    .source_node = event.source_payload,
                    .target_node = event.target_payload,
                    .source_reference = event.source_reference,
                    .source_owner = if (event.source_owner) |scope| @as(@import("../../semantic/scope.zig").ScopeId, @fromBackingInt(scope)) else null,
                    .source_reachable = reachable.contains(event.source),
                    .target_reachable = reachable.contains(event.target),
                });
            }
        }
        var provenance_changes: std.ArrayList(RetirementReceipt.ProvenanceChange) = .empty;
        defer provenance_changes.deinit(self.allocator);
        var originals = self.source_expressions.iterator();
        while (originals.next()) |entry| {
            const after = editor.node_scope_provenance.get(entry.key_ptr.*);
            if (after == null or !std.meta.eql(entry.value_ptr.*, after.?)) try provenance_changes.append(self.allocator, .{ .node = entry.key_ptr.*, .before = entry.value_ptr.*, .after = after });
        }
        var current_entries = editor.node_scope_provenance.iterator();
        while (current_entries.next()) |entry| if (!self.source_expressions.contains(entry.key_ptr.*)) {
            try provenance_changes.append(self.allocator, .{ .node = entry.key_ptr.*, .before = null, .after = entry.value_ptr.* });
        };
        const references_owned = try reference_changes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(references_owned);
        const owners_owned = try owner_changes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owners_owned);
        const provenance_owned = try provenance_changes.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(provenance_owned);
        const copies_owned = try copies.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(copies_owned);
        const names_owned = try self.allocator.dupe(@import("../../semantic/function_name_retirement.zig").Elision, self.function_name_elisions.items);
        errdefer self.allocator.free(names_owned);
        const inlined_owned = try self.allocator.dupe(InlineBinding.Event, self.inlined_bindings.items);
        return .{ .inlined_bindings = inlined_owned, .domain = self.domain, .reference_changes = references_owned, .owner_changes = owners_owned, .provenance_changes = provenance_owned, .copies = copies_owned, .function_name_elisions = names_owned };
    }

    pub fn retireInlinedBindings(self: *const SemanticJournal, editor: *SemanticEditor, root: ast_mod.NodeIndex, receipt: RetirementReceipt.ApplicationReceipt) !void {
        if (editor.ast != self.domain or receipt.domain != self.domain) return error.InvalidReferenceIdentity;
        _ = try editor.retireInlinedLocalBindings(receipt.inlined_bindings, root, receipt);
    }

    pub fn retireDeadDeclarationAnchors(self: *const SemanticJournal, editor: *SemanticEditor, root: ast_mod.NodeIndex) !void {
        if (editor.ast != self.domain) return error.InvalidReferenceIdentity;
        const nodes = try @import("../../parser/ast_walk.zig").collectReachableNodeIndicesFrom(self.allocator, editor.ast, root);
        defer self.allocator.free(nodes);
        var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer reachable.deinit(self.allocator);
        for (nodes) |raw| try reachable.put(self.allocator, raw, {});
        var index = editor.references.items.len;
        while (index > 0) {
            index -= 1;
            const row = editor.references.items[index];
            if (!row.flags.declare or row.declaration_node_index.isNone() or reachable.contains(@backingInt(row.declaration_node_index))) continue;
            _ = try editor.removeDeclarationAtNode(row.declaration_node_index, row.symbol_id);
        }
    }

    pub fn freeApplicationReceipt(self: *const SemanticJournal, receipt: RetirementReceipt.ApplicationReceipt) void {
        self.allocator.free(receipt.reference_changes);
        self.allocator.free(receipt.owner_changes);
        self.allocator.free(receipt.provenance_changes);
        self.allocator.free(receipt.copies);
        self.allocator.free(receipt.function_name_elisions);
        self.allocator.free(receipt.inlined_bindings);
    }

    /// An old aggregate is consumable only when every counted old edge has
    /// a before tuple and an actual phase-1 removal for this physical domain.
    /// No delta is used to choose a SymbolId or invent a missing reference.
    pub fn accountsForBaselineDeltas(self: *const SemanticJournal, receipt: RetirementReceipt.ApplicationReceipt, deltas: []const u32) !bool {
        if (receipt.domain != self.domain) return error.InvalidReferenceIdentity;
        if (deltas.len != 0 and deltas.len != self.symbols.len) return false;
        const counts = try self.allocator.alloc(u32, self.symbols.len);
        defer self.allocator.free(counts);
        @memset(counts, 0);
        for (self.baseline_edges.items) |edge| {
            const sid = @backingInt(edge.reference.symbol_id);
            if (sid >= counts.len) return error.InvalidReferenceIdentity;
            var accounted = false;
            for (receipt.reference_changes) |change| {
                const before = change.before orelse continue;
                if (!std.meta.eql(before, edge.reference)) continue;
                if (change.after) |after| {
                    if (after.symbol_id == before.symbol_id) return false;
                }
                if (accounted) return error.InvalidReferenceIdentity;
                accounted = true;
            }
            if (!accounted) return false;
            counts[sid] = std.math.add(u32, counts[sid], 1) catch return error.InvalidReferenceIdentity;
        }
        for (counts, 0..) |count, sid| if (count != (if (deltas.len == 0) @as(u32, 0) else deltas[sid])) return false;
        return true;
    }
};
