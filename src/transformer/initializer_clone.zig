//! Transformer ledger handoff for a typed clone of an already-built initializer.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const core = @import("../semantic/runtime_subtree_clone.zig");

/// Validate the analyzer's exact named-expression lexical boundary. Hidden
/// name scopes have no output owner node and must not be inferred from an
/// arbitrary ancestor chain.
pub fn namedExpressionScope(self: anytype, index: ast.NodeIndex, from: ScopeId) error{InvalidCloneOwnership}!ScopeId {
    if (index.isNone() or @backingInt(index) >= self.ast.nodes.items.len) return error.InvalidCloneOwnership;
    const node = self.ast.getNode(index);
    if (node.tag != .function_expression or !self.ast.hasExtra(node.data.extra, 0)) return error.InvalidCloneOwnership;
    const name = self.ast.readExtraNode(node.data.extra, 0);
    if (name.isNone() or @backingInt(name) >= self.ast.nodes.items.len or self.ast.getNode(name).tag != .binding_identifier) return error.InvalidCloneOwnership;
    const id = self.getSymbolIdAt(name) orelse return error.InvalidCloneOwnership;
    const editor = if (self.semantic_editor) |*value| value else return error.InvalidCloneOwnership;
    if (id >= editor.symbols.items.len) return error.InvalidCloneOwnership;
    const symbol = editor.symbols.items[id];
    const scope = symbol.scope_id;
    const body_scope = self.outputOwnedScope(index) orelse return error.InvalidCloneOwnership;
    if (!symbol.kind.isFunctionLike() or scope.isNone() or body_scope.isNone() or
        scope.toIndex() >= editor.scopes.items.len or body_scope.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[scope.toIndex()].kind != .block or
        editor.scopes.items[body_scope.toIndex()].kind != .function or
        editor.scopes.items[scope.toIndex()].parent != from)
        return error.InvalidCloneOwnership;
    if (editor.scopes.items[body_scope.toIndex()].parent != scope) {
        // A kept non-simple parameter list is the one explicit intermediate
        // environment. Its actual AST carrier and both parent edges must agree.
        if (!self.ast.hasExtra(node.data.extra, ast.FunctionExtra.params)) return error.InvalidCloneOwnership;
        const params = self.ast.readExtraNode(node.data.extra, ast.FunctionExtra.params);
        if (params.isNone() or @backingInt(params) >= self.ast.nodes.items.len or
            self.ast.getNode(params).tag != .formal_parameters) return error.InvalidCloneOwnership;
        const parameter_scope = self.outputOwnedScope(params) orelse return error.InvalidCloneOwnership;
        if (parameter_scope.isNone() or parameter_scope == body_scope or parameter_scope == scope or
            parameter_scope.toIndex() >= editor.scopes.items.len or editor.scopes.items[parameter_scope.toIndex()].kind != .function or
            editor.scopes.items[body_scope.toIndex()].parent != parameter_scope or
            editor.scopes.items[parameter_scope.toIndex()].parent != scope) return error.InvalidCloneOwnership;
    }
    return scope;
}

/// The actual initializer-placement producer resolves only already-bound
/// capture frame/role edges before moving its fragment into the super site.
pub fn bindPendingCaptures(self: anytype, roots: []const ast.NodeIndex) std.mem.Allocator.Error!void {
    if (!self.semantic_edit_enabled) return;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.appendSlice(self.allocator, roots);
    while (stack.pop()) |node| {
        if (node.isNone()) continue;
        const entry = try seen.getOrPut(self.allocator, @backingInt(node));
        if (entry.found_existing) continue;
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    try bindPendingNodes(self, &seen);
}

fn bindPendingNodes(self: anytype, seen: *std.AutoHashMapUnmanaged(u32, void)) std.mem.Allocator.Error!void {
    if (self.semantic_edit_enabled) {
        var reads = seen.keyIterator();
        while (reads.next()) |raw| {
            const node: ast.NodeIndex = @fromBackingInt(raw.*);
            if (self.getSymbolIdAt(node) != null) continue;
            const origin = self.reference_origin_map.get(raw.*) orelse raw.*;
            const index = self.capture_ref_by_origin.get(origin) orelse continue;
            const pending = self.capture_refs.items[index];
            const key = (@as(u64, pending.frame) << 2) | @backingInt(pending.kind);
            const id = self.capture_binding_ids.get(key) orelse @panic("cloned capture has no producer binding");
            self.addSyntheticRefInScope(node, @fromBackingInt(id), pending.scope, pending.flags) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }
}

pub fn clone(self: anytype, roots: []const ast.NodeIndex, from: ScopeId, to: ScopeId) std.mem.Allocator.Error!core.Result {
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(self.allocator);
    var stack: std.ArrayList(ast.NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.appendSlice(self.allocator, roots);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    while (stack.pop()) |node| {
        if (node.isNone()) continue;
        const gop = try seen.getOrPut(self.allocator, @backingInt(node));
        if (gop.found_existing) continue;
        if (self.outputOwnedScope(node)) |scope| try owners.put(self.allocator, @backingInt(node), @backingInt(scope));
        var children = @import("../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    try bindPendingNodes(self, &seen);
    // Named expression self bindings have a lexical-name scope without an
    // output AST owner. Admit only its exact creator shape, not an arbitrary
    // ancestor of a function body.
    var lexical_names: std.ArrayList(ScopeId) = .empty;
    defer lexical_names.deinit(self.allocator);
    if (self.semantic_editor != null) {
        var source_nodes = seen.keyIterator();
        while (source_nodes.next()) |raw| {
            const node = self.ast.getNode(@fromBackingInt(raw.*));
            if (node.tag != .function_expression) continue;
            const name = self.ast.readExtraNode(node.data.extra, 0);
            if (name.isNone()) continue;
            const scope = namedExpressionScope(self, @fromBackingInt(raw.*), from) catch @panic("named clone lost its exact lexical self scope");
            try lexical_names.append(self.allocator, scope);
        }
    }
    var implicit: std.ArrayList(SymbolId) = .empty;
    defer implicit.deinit(self.allocator);
    var class_ids = self.class_self_symbol_map.valueIterator();
    while (class_ids.next()) |id| try implicit.append(self.allocator, @fromBackingInt(id.*));
    if (self.semantic_editor) |*editor| {
        for (editor.symbols.items, 0..) |symbol, raw| {
            if (symbol.synthetic_kind) |kind| switch (kind) {
                .implicit_arguments, .namespace_iife_parameter, .enum_iife_parameter => try implicit.append(self.allocator, @fromBackingInt(@as(u32, @intCast(raw)))),
                else => {},
            };
        }
    }
    const result = if (self.semantic_edit_enabled) blk: {
        const editor = if (self.semantic_editor) |*value| value else @panic("typed initializer clone has no semantic owner");
        break :blk core.clone(self.allocator, self.ast, editor, roots, &owners, lexical_names.items, implicit.items, from, to) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("invalid typed initializer clone: {s}", .{@errorName(err)}),
        };
    } else core.cloneAst(self.allocator, self.ast, roots, from, to) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("invalid legacy initializer AST clone: {s}", .{@errorName(err)}),
    };
    errdefer {
        var failed = result;
        failed.deinit(self.allocator);
    }
    const old_slots = self.symbol_ids.items.len;
    if (old_slots < self.ast.nodes.items.len) {
        try self.symbol_ids.resize(self.allocator, self.ast.nodes.items.len);
        @memset(self.symbol_ids.items[old_slots..], null);
    }
    if (comptime @hasField(@TypeOf(self.*), "native_arguments_declaration_origins")) {
        // Only an owned SID present in the source ledger creates a cloned
        // engine declaration. External function engines stay on their owner.
        var symbols = result.symbols.iterator();
        while (symbols.next()) |entry| {
            const origin = self.native_arguments_declaration_origins.get(entry.key_ptr.*) orelse continue;
            const scope = result.scope(origin);
            const symbol = self.semantic_editor.?.symbols.items[@backingInt(entry.value_ptr.*)];
            if (scope == origin or symbol.scope_id != scope or symbol.synthetic_kind != .implicit_arguments)
                @panic("cloned arguments engine lost its exact owned scope");
            try self.native_arguments_declaration_origins.put(self.allocator, @backingInt(entry.value_ptr.*), scope);
        }
    }
    var nodes = result.nodes.iterator();
    while (nodes.next()) |entry| {
        const original = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        const raw = @backingInt(node);
        if (comptime @hasField(@TypeOf(self.*), "native_arguments_reference_origins")) {
            if (self.native_arguments_reference_origins.get(original)) |source_origin| {
                var origin = source_origin;
                origin.symbol_id = result.symbols.get(@backingInt(origin.symbol_id)) orelse origin.symbol_id;
                origin.owner_scope = result.scope(origin.owner_scope);
                origin.scope = result.scope(origin.scope);
                origin.stmt = @import("../semantic/symbol.zig").Reference.NO_STMT;
                origin.scope_stmt = @import("../semantic/symbol.zig").Reference.NO_STMT;
                if (self.semantic_editor.?.symbol_ids.items[raw] != @as(?u32, @backingInt(origin.symbol_id)))
                    @panic("cloned native arguments reference lost its owned identity");
                try self.native_arguments_reference_origins.put(self.allocator, raw, origin);
            }
        }
        if (self.generated_super_call_assignments.get(original)) |source| {
            if (!source.native and source.pending_result_producer_id != 0)
                @panic("cloned super result has no published producer identity");
            var copied = source;
            copied.constructor_scope = result.scope(source.constructor_scope);
            copied.use_scope = result.scope(source.use_scope);
            if (source.target_symbol) |id| copied.target_symbol = result.sid(id);
            if (source.callee_symbol) |id| copied.callee_symbol = result.sid(id);
            if (source.check_symbol) |id| copied.check_symbol = result.sid(id);
            if (source.result_symbol) |id| copied.result_symbol = result.sid(id);
            copied.result_scope = result.scope(source.result_scope);
            if (!source.result_assignment.isNone())
                copied.result_assignment = result.nodes.get(@backingInt(source.result_assignment)) orelse @panic("cloned super binding lost its result producer");
            if (!source.evaluation_sequence.isNone())
                copied.evaluation_sequence = result.nodes.get(@backingInt(source.evaluation_sequence)) orelse @panic("cloned super binding lost its evaluation producer");
            try self.generated_super_call_assignments.put(self.allocator, raw, copied);
        }
        if (self.synthetic_idents) |*set| if (set.contains(original)) try set.put(self.allocator, raw, {});
        if (self.runtime_helper_ref_index.contains(original)) {
            try self.helper_ref_nodes.append(self.allocator, raw);
            try self.runtime_helper_ref_index.put(self.allocator, raw, {});
        }
        if (!self.semantic_edit_enabled) {
            try self.copySymbolId(@fromBackingInt(original), node);
            continue;
        }
        const editor = &self.semantic_editor.?;
        const id = editor.symbol_ids.items[raw];
        self.symbol_ids.items[raw] = id;
        if (editor.scope_owner_map.get(raw)) |scope| try self.transformed_scope_owner_map.put(self.allocator, raw, scope);
        if (self.class_self_symbol_map.get(original)) |old_id| try self.class_self_symbol_map.put(self.allocator, raw, @backingInt(result.sid(@fromBackingInt(old_id))));
        const source_node: ast.NodeIndex = @fromBackingInt(original);
        if (editor.node_scope_provenance.get(source_node)) |source| {
            var copied = source;
            copied.scope = result.scope(source.scope);
            try editor.node_scope_provenance.put(self.allocator, node, copied);
            try self.transformed_node_scope_provenance.put(self.allocator, node, copied);
            self.node_scope_provenance_changed = true;
        }
        if (self.explicit_global_reference_nodes.contains(original) or
            (if (self.unresolved_reference_nodes) |set| set.contains(original) else false))
        {
            try self.explicit_global_reference_nodes.put(self.allocator, raw, {});
            try self.reference_origin_map.put(self.allocator, raw, self.reference_origin_map.get(original) orelse original);
        }
        if (self.tracked_runtime_helper_ref_index.get(original)) |tracked| {
            const source = self.tracked_runtime_helper_refs.items[tracked];
            if (id != source.symbol_id) @panic("runtime helper clone changed its external SID");
            const index = self.tracked_runtime_helper_refs.items.len;
            try self.tracked_runtime_helper_refs.append(self.allocator, .{ .node = node, .scope = result.scope(source.scope), .symbol_id = source.symbol_id });
            try self.tracked_runtime_helper_ref_index.put(self.allocator, raw, index);
        }
        if (editor.referenceForNode(node) catch @panic("cloned initializer reference index is invalid")) |row| {
            if (row.flags.declare) continue;
            const source = (editor.referenceForNode(source_node) catch @panic("source initializer reference index is invalid")) orelse @panic("cloned initializer reference lost its source origin");
            if (row.symbol_id != result.sid(source.symbol_id) or row.scope_id != result.scope(source.scope_id) or !std.meta.eql(row.flags, source.flags))
                @panic("cloned initializer reference changed its exact source contract");
            try self.trackExactOutputReferenceInScope(node, @backingInt(row.symbol_id), row.scope_id);
            try @import("native_constructor_guard.zig").recordReference(self, node, row.symbol_id, row.scope_id, row.flags);
            if (self.private_helper_symbol_ids.contains(self.getSymbolIdAt(source_node) orelse std.math.maxInt(u32)))
                try self.private_helper_symbol_ids.put(self.allocator, @backingInt(row.symbol_id), {});
        }
    }
    return result;
}
