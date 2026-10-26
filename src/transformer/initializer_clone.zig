//! Transformer ledger handoff for a typed clone of an already-built initializer.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const core = @import("../semantic/runtime_subtree_clone.zig");

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
        break :blk core.clone(self.allocator, self.ast, editor, roots, &owners, implicit.items, from, to) catch |err| switch (err) {
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
    var nodes = result.nodes.iterator();
    while (nodes.next()) |entry| {
        const original = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        const raw = @backingInt(node);
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
