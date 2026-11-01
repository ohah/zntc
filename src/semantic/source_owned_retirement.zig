//! Persistent graph state for source identities retired by an exact producer.
//! This never changes a SymbolId's source storage/origin scope or declaration.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const symbols = @import("symbol.zig");
const ScopeId = @import("scope.zig").ScopeId;

pub const Witness = struct {
    symbol_id: symbols.SymbolId,
    before: symbols.Symbol,
    declaration: symbols.Reference,
    declaration_node: ?ast.Node,
    source_owner: ast.NodeIndex,
    source_owner_node: ast.Node,
    source_scope: ScopeId,
    source_parent: ScopeId,
    source_name: ast.NodeIndex,
    source_name_symbol: symbols.SymbolId,
    closure_scope: ScopeId,
    closure_parent: ScopeId,
    reason: enum { source_function_closure, erased_import_binding, erased_const_enum_binding, static_class_capture_alias, elided_function_name, erased_const_enum_environment },
    erased_import: ?@import("import_erasure.zig").Binding = null,
    static_capture_alias: ?@import("static_capture_retirement.zig").Witness = null,
    function_name_elision: ?@import("function_name_retirement.zig").Witness = null,
    enum_environment: ?@import("enum_environment_retirement.zig").Witness = null,
};

pub const Map = std.AutoHashMapUnmanaged(u32, Witness);

/// Additional published roots owned by a caller (exports/runtime metadata),
/// never inferred from names. A retired identity cannot remain one of these.
pub const Roots = struct {
    runtime_output_proof: ?@import("output_runtime_coverage.zig").Proof = null,
    symbol_ids: []const u32 = &.{},
    scope_history: ?*const @import("scope_frame_history.zig").History = null,
    node_scope_provenance: *const @import("node_scope_provenance.zig").Map,
    runtime_helper_symbols: ?*const std.StringHashMapUnmanaged(symbols.SymbolId) = null,
    class_self_symbols: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
    namespace_member_owners: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
    namespace_declaration_owners: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
};

pub fn equalSymbol(a: symbols.Symbol, b: symbols.Symbol) bool {
    if (!std.mem.eql(u8, a.synthetic_name, b.synthetic_name) or !std.mem.eql(u8, a.output_name_hint, b.output_name_hint)) return false;
    var left = a;
    var right = b;
    left.synthetic_name = "";
    right.synthetic_name = "";
    left.output_name_hint = "";
    right.output_name_hint = "";
    return std.meta.eql(left, right);
}

fn below(scopes: []const @import("scope.zig").Scope, start: ScopeId, ancestor: ScopeId) bool {
    var cursor = start;
    var fuel = scopes.len + 1;
    while (!cursor.isNone() and fuel > 0) : (fuel -= 1) {
        if (cursor.toIndex() >= scopes.len) return false;
        if (cursor == ancestor) return true;
        cursor = scopes[cursor.toIndex()].parent;
    }
    return false;
}

pub fn validate(
    allocator: std.mem.Allocator,
    ast_ptr: *const ast.Ast,
    state: *const Map,
    reachable: *const std.DynamicBitSet,
    symbol_rows: []const symbols.Symbol,
    symbol_ids: []const ?u32,
    scopes: []const @import("scope.zig").Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    owners: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const symbols.Reference,
    helper_map: *const std.StringHashMapUnmanaged(usize),
    roots: Roots,
) std.mem.Allocator.Error!bool {
    if (state.count() == 0) {
        var uses = roots.node_scope_provenance.valueIterator();
        while (uses.next()) |use| if (use.external_import != null) return false;
        return true;
    }
    var closure_roots = try std.DynamicBitSet.initEmpty(allocator, scopes.len);
    defer closure_roots.deinit();
    var declaration_anchors = try std.DynamicBitSet.initEmpty(allocator, symbol_ids.len);
    defer declaration_anchors.deinit();
    var argument_scopes = try std.DynamicBitSet.initEmpty(allocator, scopes.len);
    defer argument_scopes.deinit();
    var source_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer source_owners.deinit(allocator);
    var entries = state.iterator();
    while (entries.next()) |entry| {
        const sid = entry.key_ptr.*;
        const witness = entry.value_ptr.*;
        if (witness.reason == .erased_const_enum_environment) {
            if (@backingInt(witness.symbol_id) != sid) return false;
            if (!try @import("enum_environment_retirement.zig").validate(allocator, witness, state, ast_ptr, reachable, symbol_rows, symbol_ids, scopes, owners, roots.scope_history)) return false;
            closure_roots.set(witness.source_scope.toIndex());
            continue;
        }
        if (witness.enum_environment != null) return false;
        if (witness.reason == .elided_function_name) {
            if (@backingInt(witness.symbol_id) != sid or !@import("function_name_retirement.zig").validateState(witness, ast_ptr, reachable, symbol_rows, symbol_ids, scopes, owners, references)) return false;
            const raw = @backingInt(witness.declaration.declaration_node_index);
            if (raw >= declaration_anchors.capacity() or declaration_anchors.isSet(raw)) return false;
            declaration_anchors.set(raw);
            closure_roots.set(witness.closure_scope.toIndex());
            continue;
        }
        if (witness.function_name_elision != null) return false;
        if (witness.reason == .static_class_capture_alias) {
            if (@backingInt(witness.symbol_id) != sid) return false;
            if (!@import("static_capture_retirement.zig").validateState(witness, ast_ptr, reachable, symbol_rows, symbol_ids, scopes, owners, references)) return false;
            const declaration = witness.declaration.declaration_node_index;
            if (declaration.isNone() or @backingInt(declaration) >= declaration_anchors.capacity() or declaration_anchors.isSet(@backingInt(declaration))) return false;
            declaration_anchors.set(@backingInt(declaration));
            var expected = witness.before;
            expected.reference_count = 0;
            expected.write_count = 0;
            if (!equalSymbol(expected, symbol_rows[sid])) return false;
            continue;
        }
        if (witness.static_capture_alias != null) return false;
        if (witness.reason == .erased_import_binding) {
            const binding = witness.erased_import orelse return false;
            if (sid >= symbol_rows.len or @backingInt(witness.symbol_id) != sid or
                !@import("import_erasure.zig").validatesBinding(ast_ptr, binding) or
                witness.source_owner != binding.specifier or !@import("import_erasure.zig").equalNode(witness.source_owner_node, binding.specifier_node) or
                witness.source_name != binding.local or witness.source_name_symbol != witness.symbol_id or
                !witness.closure_scope.isNone() or !witness.closure_parent.isNone() or
                reachable.isSet(@backingInt(binding.local)) or reachable.isSet(@backingInt(binding.specifier)) or
                witness.source_scope.isNone() or witness.source_scope.toIndex() >= scopes.len or
                witness.source_parent != scopes[witness.source_scope.toIndex()].parent) return false;
            const before = witness.before;
            if (before.kind != .import_binding or before.isSynthetic() or before.synthetic_name.len != 0 or before.output_name_hint.len != 0 or
                before.scope_id != witness.source_scope or before.origin_scope != before.scope_id or
                before.synthetic_owner_id != null or before.isExported() or
                !before.annex_b_alias.variable.isNone() or before.annex_b_alias.state != .native or
                !before.parameter_copy.parameter_source.isNone() or
                !std.meta.eql(before.name, binding.local_node.span) or !std.meta.eql(before.declaration_span, binding.specifier_node.span) or
                (binding.policy == .unused and (before.reference_count != 0 or before.write_count != 0))) return false;
            const declaration = witness.declaration;
            if (declaration.symbol_id != witness.symbol_id or declaration.scope_id != before.scope_id or
                !declaration.node_index.isNone() or declaration.declaration_node_index != binding.local or
                !std.meta.eql(declaration.flags, @as(symbols.ReferenceFlags, .{ .declare = true }))) return false;
            const local_node = witness.declaration_node orelse return false;
            if (!@import("import_erasure.zig").equalNode(local_node, binding.local_node) or
                @backingInt(binding.local) >= symbol_ids.len or declaration_anchors.isSet(@backingInt(binding.local))) return false;
            declaration_anchors.set(@backingInt(binding.local));
            var expected = before;
            expected.reference_count = 0;
            expected.write_count = 0;
            if (!equalSymbol(expected, symbol_rows[sid])) return false;
            continue;
        }
        if (witness.reason == .erased_const_enum_binding) {
            if (witness.erased_import != null or sid >= symbol_rows.len or @backingInt(witness.symbol_id) != sid or
                witness.source_owner.isNone() or @backingInt(witness.source_owner) >= ast_ptr.nodes.items.len or
                witness.source_name.isNone() or @backingInt(witness.source_name) >= symbol_ids.len or
                witness.source_name_symbol != witness.symbol_id or !witness.closure_scope.isNone() or !witness.closure_parent.isNone() or
                witness.source_owner_node.tag != .ts_enum_declaration or !ast_ptr.hasExtra(witness.source_owner_node.data.extra, ast.EnumExtra.flags) or
                ast_ptr.readExtra(witness.source_owner_node.data.extra, ast.EnumExtra.flags) != 1 or
                ast_ptr.readExtra(witness.source_owner_node.data.extra, ast.EnumExtra.name) != @backingInt(witness.source_name) or
                ast_ptr.getNode(witness.source_owner).tag != witness.source_owner_node.tag or
                !std.meta.eql(ast_ptr.getNode(witness.source_owner).span, witness.source_owner_node.span) or
                ast_ptr.getNode(witness.source_owner).data.extra != witness.source_owner_node.data.extra or
                reachable.isSet(@backingInt(witness.source_owner)) or reachable.isSet(@backingInt(witness.source_name)) or
                witness.source_scope.isNone() or witness.source_scope.toIndex() >= scopes.len or
                witness.source_parent != scopes[witness.source_scope.toIndex()].parent) return false;
            const before = witness.before;
            if ((before.kind != .variable_let and before.kind != .variable_var) or before.isSynthetic() or before.isExported() or
                before.synthetic_name.len != 0 or before.output_name_hint.len != 0 or before.synthetic_owner_id != null or
                before.scope_id != witness.source_scope or before.origin_scope != before.scope_id or
                !std.meta.eql(before.declaration_span, witness.source_owner_node.span) or
                scopes[before.scope_id.toIndex()].blocksMangling()) return false;
            const declaration = witness.declaration;
            const binding = witness.declaration_node orelse return false;
            if (binding.tag != .binding_identifier or !@import("import_erasure.zig").equalNode(ast_ptr.getNode(witness.source_name), binding) or
                !std.meta.eql(binding.span, before.name) or declaration.symbol_id != witness.symbol_id or declaration.scope_id != before.scope_id or
                !declaration.node_index.isNone() or declaration.declaration_node_index != witness.source_name or
                !std.meta.eql(declaration.flags, @as(symbols.ReferenceFlags, .{ .declare = true })) or declaration_anchors.isSet(@backingInt(witness.source_name))) return false;
            declaration_anchors.set(@backingInt(witness.source_name));
            var expected = before;
            expected.reference_count = 0;
            expected.write_count = 0;
            if (!equalSymbol(expected, symbol_rows[sid])) return false;
            continue;
        }
        if (witness.erased_import != null) return false;
        if (sid >= symbol_rows.len or @backingInt(witness.symbol_id) != sid or witness.source_owner.isNone() or
            @backingInt(witness.source_owner) >= ast_ptr.nodes.items.len or reachable.isSet(@backingInt(witness.source_owner)) or
            witness.source_scope.isNone() or witness.closure_scope.isNone() or witness.source_scope.toIndex() >= scopes.len or witness.closure_scope.toIndex() >= scopes.len) return false;
        if (scopes[witness.source_scope.toIndex()].kind != .function or scopes[witness.source_scope.toIndex()].parent.isNone() or
            witness.source_parent != scopes[witness.source_scope.toIndex()].parent or witness.closure_parent != scopes[witness.closure_scope.toIndex()].parent or
            scopes[witness.source_scope.toIndex()].blocksMangling() or scopes[witness.closure_scope.toIndex()].blocksMangling()) return false;
        const owner_entry = try source_owners.getOrPut(allocator, @backingInt(witness.source_owner));
        if (owner_entry.found_existing) {
            const previous = state.get(owner_entry.value_ptr.*).?;
            if (previous.source_scope != witness.source_scope or previous.source_parent != witness.source_parent or
                previous.source_name != witness.source_name or previous.source_name_symbol != witness.source_name_symbol or
                previous.closure_scope != witness.closure_scope or previous.closure_parent != witness.closure_parent or
                previous.source_owner_node.tag != witness.source_owner_node.tag or !std.meta.eql(previous.source_owner_node.span, witness.source_owner_node.span) or
                previous.source_owner_node.data.extra != witness.source_owner_node.data.extra) return false;
        } else owner_entry.value_ptr.* = sid;
        const before = witness.before;
        if (before.scope_id.isNone() or before.origin_scope.isNone() or before.scope_id.toIndex() >= scopes.len or before.origin_scope.toIndex() >= scopes.len or
            scopes[before.scope_id.toIndex()].blocksMangling() or scopes[before.origin_scope.toIndex()].blocksMangling() or
            before.isExported() or before.synthetic_owner_id != null or before.output_name_hint.len != 0 or
            !before.annex_b_alias.variable.isNone() or before.annex_b_alias.state != .native) return false;
        const intrinsic_arguments = before.synthetic_kind == .implicit_arguments and before.kind == .parameter and
            std.mem.eql(u8, before.synthetic_name, "arguments") and before.scope_id == before.origin_scope;
        if ((before.isSynthetic() or before.synthetic_name.len != 0) and !intrinsic_arguments) return false;
        if (intrinsic_arguments and (before.scope_id != witness.source_scope or
            (witness.source_owner_node.tag != .function_expression and witness.source_owner_node.tag != .function_declaration) or
            !std.meta.eql(before.declaration_span, witness.source_owner_node.span))) return false;
        switch (witness.source_owner_node.tag) {
            .function_declaration, .function_expression, .arrow_function_expression => {},
            else => return false,
        }
        if (witness.source_owner_node.span.start > witness.source_owner_node.span.end or witness.source_owner_node.span.end > ast_ptr.source.len or
            before.declaration_span.start < witness.source_owner_node.span.start or before.declaration_span.end > witness.source_owner_node.span.end) return false;
        const named_expression = witness.source_owner_node.tag == .function_expression and !witness.source_name.isNone();
        if (named_expression) {
            if (witness.source_name_symbol.isNone() or witness.closure_scope != scopes[witness.source_scope.toIndex()].parent or
                scopes[witness.closure_scope.toIndex()].kind != .block or scopes[witness.closure_scope.toIndex()].parent.isNone() or
                scopes[witness.closure_scope.toIndex()].parent.toIndex() >= scopes.len) return false;
            const self = state.get(@backingInt(witness.source_name_symbol)) orelse return false;
            if (self.source_owner != witness.source_owner or self.source_scope != witness.source_scope or self.closure_scope != witness.closure_scope or
                self.declaration.declaration_node_index != witness.source_name or self.before.scope_id != witness.closure_scope or self.before.origin_scope != witness.closure_scope) return false;
        } else if (witness.closure_scope != witness.source_scope) return false;
        const outer_declaration = witness.source_owner_node.tag == .function_declaration and witness.source_name_symbol == witness.symbol_id and
            witness.source_name == witness.declaration.declaration_node_index and before.scope_id == scopes[witness.source_scope.toIndex()].parent and before.origin_scope == before.scope_id;
        if (!outer_declaration and (!below(scopes, before.scope_id, witness.closure_scope) or !below(scopes, before.origin_scope, witness.closure_scope))) return false;
        const declaration = witness.declaration;
        if (declaration.symbol_id != witness.symbol_id or declaration.scope_id != before.scope_id or !declaration.node_index.isNone() or
            !std.meta.eql(declaration.flags, @as(symbols.ReferenceFlags, .{ .declare = true }))) return false;
        if (witness.declaration_node) |node| {
            if (declaration.declaration_node_index.isNone() or @backingInt(declaration.declaration_node_index) >= symbol_ids.len or
                node.tag != .binding_identifier or !std.meta.eql(node.span, before.name) or reachable.isSet(@backingInt(declaration.declaration_node_index))) return false;
            const raw = @backingInt(declaration.declaration_node_index);
            if (declaration_anchors.isSet(raw)) return false;
            declaration_anchors.set(raw);
        } else {
            if (!intrinsic_arguments or !declaration.declaration_node_index.isNone() or argument_scopes.isSet(before.scope_id.toIndex())) return false;
            argument_scopes.set(before.scope_id.toIndex());
        }
        var expected = before;
        expected.reference_count = 0;
        expected.write_count = 0;
        if (!equalSymbol(expected, symbol_rows[sid])) return false;
        closure_roots.set(witness.closure_scope.toIndex());
    }
    // One edge census for the complete state, rather than rescanning the
    // whole program separately for each retired SymbolId.
    var inactive = try std.DynamicBitSet.initEmpty(allocator, scopes.len);
    defer inactive.deinit();
    for (scopes, 0..) |_, raw| {
        var cursor: ScopeId = @fromBackingInt(@as(u32, @intCast(raw)));
        var fuel = scopes.len + 1;
        while (!cursor.isNone() and fuel > 0) : (fuel -= 1) {
            if (cursor.toIndex() >= scopes.len) return false;
            if (closure_roots.isSet(cursor.toIndex())) {
                inactive.set(raw);
                break;
            }
            cursor = scopes[cursor.toIndex()].parent;
        }
        if (fuel == 0) return false;
    }
    for (symbol_ids) |id| if (id) |sid| if (state.contains(sid)) return false;
    for (references) |row| {
        if (state.contains(@backingInt(row.symbol_id)) or row.scope_id.isNone() or row.scope_id.toIndex() >= scopes.len or inactive.isSet(row.scope_id.toIndex())) return false;
    }
    for (scope_maps, 0..) |map, raw| {
        if (raw >= scopes.len or (inactive.isSet(raw) and map.count() != 0)) return false;
        var values = map.valueIterator();
        while (values.next()) |value| if (state.contains(@intCast(value.*))) return false;
    }
    var helper_values = helper_map.valueIterator();
    while (helper_values.next()) |value| if (state.contains(@intCast(value.*))) return false;
    var owner_values = owners.valueIterator();
    while (owner_values.next()) |scope| if (scope.* >= scopes.len or inactive.isSet(scope.*)) return false;
    var provenance = roots.node_scope_provenance.iterator();
    while (provenance.next()) |entry| {
        if (entry.value_ptr.scope.isNone() or entry.value_ptr.scope.toIndex() >= scopes.len or inactive.isSet(entry.value_ptr.scope.toIndex())) return false;
        if (entry.value_ptr.external_import) |origin| {
            const retired = state.get(@backingInt(origin.binding_symbol)) orelse return false;
            const raw = @backingInt(entry.key_ptr.*);
            if ((retired.reason != .erased_import_binding and retired.reason != .erased_const_enum_binding) or raw >= ast_ptr.nodes.items.len or raw >= symbol_ids.len or symbol_ids[raw] != null or
                !reachable.isSet(raw) or entry.value_ptr.source_node != origin.before.node_index or
                origin.before.symbol_id != origin.binding_symbol or origin.before.flags.declare or
                !origin.before.declaration_node_index.isNone() or origin.before.scope_id.isNone() or origin.before.scope_id.toIndex() >= scopes.len) return false;
            const node = ast_ptr.nodes.items[raw];
            switch (node.tag) {
                .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
                else => return false,
            }
            if (node.tag != origin.before_tag or !std.meta.eql(node.data.string_ref, origin.before_name) or !std.meta.eql(node.span, origin.before_span)) return false;
            if (origin.before.node_index.isNone() or @backingInt(origin.before.node_index) >= ast_ptr.nodes.items.len) return false;
        }
    }
    for (roots.symbol_ids) |sid| if (state.contains(sid)) return false;
    if (roots.runtime_helper_symbols) |map| {
        var values = map.valueIterator();
        while (values.next()) |value| if (state.contains(@backingInt(value.*))) return false;
    }
    inline for (.{ roots.class_self_symbols, roots.namespace_member_owners, roots.namespace_declaration_owners }) |maybe_map| if (maybe_map) |map| {
        var pairs = map.iterator();
        while (pairs.next()) |pair| {
            if (state.contains(pair.value_ptr.*)) return false;
            // Namespace maps use semantic IDs for both ends; class-self keys
            // are actual AST nodes, not SymbolIds.
        }
    };
    if (roots.namespace_member_owners) |map| {
        var keys = map.keyIterator();
        while (keys.next()) |sid| if (state.contains(sid.*)) return false;
    }
    if (roots.namespace_declaration_owners) |map| {
        var keys = map.keyIterator();
        while (keys.next()) |sid| if (state.contains(sid.*)) return false;
    }
    for (symbol_rows, 0..) |other, sid| {
        if (!other.scope_id.isNone() and other.scope_id.toIndex() < scopes.len and inactive.isSet(other.scope_id.toIndex()) and !state.contains(@intCast(sid))) return false;
        if (other.synthetic_owner_id) |owner| if (state.contains(@backingInt(owner))) {
            const retired = state.get(@intCast(sid)) orelse return false;
            if (!@import("enum_environment_retirement.zig").validRetiredOwner(retired, state)) return false;
        };
        if ((!other.annex_b_alias.variable.isNone() and state.contains(@backingInt(other.annex_b_alias.variable))) or
            (!other.parameter_copy.parameter_source.isNone() and state.contains(@backingInt(other.parameter_copy.parameter_source)))) return false;
    }
    return true;
}

/// Used only by NormalForm after validate() and the actual frame/provenance
/// replay succeed for the same query backings. Public Exact/Strict pass no map.
/// The live engine keeps both its current storage and historical origin IDs;
/// only this proved, retired parameter-environment ancestry is non-lexical.
pub fn hasHistoricalArgumentsOrigin(state: *const Map, sid: u32, current: symbols.Symbol) bool {
    if (current.kind != .parameter or current.synthetic_kind != .implicit_arguments or current.scope_id.isNone() or
        current.origin_scope.isNone() or current.scope_id == current.origin_scope or !std.mem.eql(u8, current.synthetic_name, "arguments")) return false;
    var entries = state.valueIterator();
    while (entries.next()) |retired| {
        if (retired.reason != .elided_function_name) continue;
        const name = retired.function_name_elision orelse continue;
        const engine = name.engine orelse continue;
        if (@backingInt(engine.symbol_id) != sid or !name.retire_parameters or name.parameter_scope.isNone() or current.origin_scope != name.parameter_scope or current.scope_id != name.body_scope or
            name.parameter_frame.kind != .function or name.parameter_frame.symbol_count != 0 or name.parameter_frame.parent != name.name_scope or
            name.body_frame.kind != .function or name.body_frame.parent != name.parameter_scope or
            engine.before.origin_scope != name.parameter_scope or engine.before.scope_id != name.body_scope or engine.before.synthetic_kind != .implicit_arguments or
            engine.before.kind != .parameter or !std.mem.eql(u8, engine.before.synthetic_name, "arguments") or
            engine.declaration.symbol_id != engine.symbol_id or engine.declaration.scope_id != name.body_scope or !engine.declaration.node_index.isNone() or
            !engine.declaration.declaration_node_index.isNone() or !std.meta.eql(engine.declaration.flags, @as(symbols.ReferenceFlags, .{ .declare = true }))) continue;
        var before = engine.before;
        before.reference_count = current.reference_count;
        before.write_count = current.write_count;
        if (equalSymbol(before, current)) return true;
    }
    return false;
}
