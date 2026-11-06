//! Query-local class-self owner authority for the original-graph prepass.
//! Source classes come from the transaction's immutable input pair, not from
//! names or an arbitrary current ancestor. Buffer/const queries never use it.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const Module = @import("../bundler/module.zig").Module;
const Semantic = @import("../bundler/module.zig").ModuleSemanticData;
const History = @import("scope_frame_history.zig");
const Worklet = @import("lowered_worklet_class.zig");
const N = ast.NodeIndex;

pub const Source = struct {
    tree: *const ast.Ast,
    semantic: *const Semantic,
};
/// Independently captured by the private PreparedGeneric transaction after
/// its two immutable snapshots and candidate have their actual addresses.
/// Swapping an equal-text Source from another transaction cannot move it.
pub const Receipt = struct {
    input: *const Module,
    candidate: *const Module,
    candidate_owner: @import("../bundler/module.zig").SemanticOwnerToken,
    input_ast: *const ast.Ast,
    input_semantic: *const Semantic,
    owner: @import("../bundler/codegen_output_domain.zig").Owner,
    tree: *const ast.Ast,
    semantic: *const Semantic,
    nodes: []const ast.Node,
    extras: []const u32,
    ids: []const ?u32,
    symbols: []const @import("symbol.zig").Symbol,

    pub fn capture(input: *const Module, candidate: *Module, source: Source) Receipt {
        // Reserve only for the immutable input's actual class-owner domain.
        // Class-free prepasses retain the existing zero-owner fast path.
        // Input ownership stays lazy on abort; later class certificates reuse
        // this exact staged label instead of minting an unrelated one.
        const has_source_class = for (source.semantic.scope_history.source_owners) |binding| {
            if (binding.owner.tag == .class_declaration or binding.owner.tag == .class_expression) break true;
        } else false;
        const candidate_owner = if (has_source_class) candidate.semantic.?.captureOwnerToken() else candidate.semantic.?.owner_token;
        return .{ .input = input, .candidate = candidate, .candidate_owner = candidate_owner, .input_ast = &input.ast.?, .input_semantic = &input.semantic.?, .owner = input.codegen_output_owner, .tree = source.tree, .semantic = source.semantic, .nodes = source.tree.nodes.items, .extras = source.tree.extra_data.items, .ids = source.semantic.symbol_ids, .symbols = source.semantic.symbols.items };
    }
    fn matches(self: *const Receipt, module: *const Module, source: Source) bool {
        return self.candidate == module and module.semantic != null and
            self.candidate_owner != .unassigned and self.candidate_owner == module.semantic.?.owner_token and self.input.ast != null and self.input.semantic != null and
            self.input_ast == &self.input.ast.? and self.input_semantic == &self.input.semantic.? and
            self.input.semantic.?.owner_token == source.semantic.owner_token and
            self.owner == self.input.codegen_output_owner and self.owner == module.codegen_output_owner and
            self.tree == source.tree and self.semantic == source.semantic and
            self.nodes.ptr == source.tree.nodes.items.ptr and self.nodes.len == source.tree.nodes.items.len and
            self.extras.ptr == source.tree.extra_data.items.ptr and self.extras.len == source.tree.extra_data.items.len and
            self.ids.ptr == source.semantic.symbol_ids.ptr and self.ids.len == source.semantic.symbol_ids.len and
            self.symbols.ptr == source.semantic.symbols.items.ptr and self.symbols.len == source.semantic.symbols.items.len and
            self.input.source.ptr == module.source.ptr and self.input.source.len == module.source.len;
    }
};
const Class = struct {
    node: N,
    body: N,
    name: N,
    scope: @import("scope.zig").ScopeId,
    sid: u32,
};
pub const Proof = struct {
    module: *const Module,
    semantic: *const Semantic,
    allowed: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn deinit(self: *Proof, a: std.mem.Allocator) void {
        self.allowed.deinit(a);
    }
    pub fn allows(self: *const Proof, module: *const Module, semantic: anytype, owner: u32, sid: u32) bool {
        return module == self.module and @as(*const anyopaque, @ptrCast(semantic)) == @as(*const anyopaque, @ptrCast(self.semantic)) and
            self.allowed.get(owner) == @as(?u32, sid);
    }
    fn add(self: *Proof, a: std.mem.Allocator, node: N, sid: u32) !bool {
        const entry = try self.allowed.getOrPut(a, @backingInt(node));
        if (entry.found_existing and entry.value_ptr.* != sid) return false;
        entry.value_ptr.* = sid;
        return true;
    }
};
fn present(tree: *const ast.Ast, node: N) bool {
    return !node.isNone() and @backingInt(node) < tree.nodes.items.len;
}
fn live(nodes: *const std.DynamicBitSet, node: N) bool {
    return !node.isNone() and @backingInt(node) < nodes.capacity() and nodes.isSet(@backingInt(node));
}
const RowSummary = struct { total: usize = 0, anchorless: usize = 0, physical_declaration: N = .none };
fn anchorlessRows(a: std.mem.Allocator, sem: *const Semantic) !std.AutoHashMapUnmanaged(u32, RowSummary) {
    var result: std.AutoHashMapUnmanaged(u32, RowSummary) = .empty;
    errdefer result.deinit(a);
    for (sem.references) |row| {
        const sid = @backingInt(row.symbol_id);
        const entry = try result.getOrPut(a, sid);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.total += 1;
        if (sid < sem.symbols.items.len and row.scope_id == sem.symbols.items[sid].scope_id and
            row.flags.declare and !row.flags.read and !row.flags.write and !row.flags.type_context and !row.flags.value_as_type and
            row.node_index.isNone() and row.declaration_node_index.isNone()) entry.value_ptr.anchorless += 1;
        if (sid < sem.symbols.items.len and row.scope_id == sem.symbols.items[sid].scope_id and
            row.flags.declare and !row.flags.read and !row.flags.write and !row.flags.type_context and !row.flags.value_as_type and
            row.node_index.isNone() and !row.declaration_node_index.isNone()) entry.value_ptr.physical_declaration = row.declaration_node_index;
    }
    return result;
}
fn contains(a: std.mem.Allocator, tree: *const ast.Ast, root: N, wanted: N) !bool {
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, tree, root);
    defer a.free(nodes);
    for (nodes) |raw| if (raw == @backingInt(wanted)) return true;
    return false;
}

/// This producer appends the declaration directly to its generated arrow's
/// block. Inspect that bounded list, never descendants of nested classes.
fn wrapperDirectlyOwnsDeclaration(tree: *const ast.Ast, wrapper: N, declaration: N) bool {
    if (!present(tree, wrapper) or !present(tree, declaration)) return false;
    const function = tree.getNode(wrapper);
    if (function.tag != .arrow_function_expression or !tree.hasExtra(function.data.extra, ast.ArrowExtra.body)) return false;
    const body = tree.readExtraNode(function.data.extra, ast.ArrowExtra.body);
    if (!present(tree, body)) return false;
    const block = tree.getNode(body);
    if (block.tag != .block_statement) return false;
    const start: usize = block.data.list.start;
    const len: usize = block.data.list.len;
    if (start > tree.extra_data.items.len or len > tree.extra_data.items.len - start) return false;
    var matches: usize = 0;
    for (tree.extra_data.items[start..][0..len]) |raw| {
        if (raw == @backingInt(declaration)) matches += 1;
    }
    return matches == 1;
}

/// Construct once for this output. History and the Worklet bridge are validated
/// once, and owner/SID selections are indexed before the caller scans sidecars.
/// No new source/retirement/wire metadata is published by this query.
pub fn prepare(a: std.mem.Allocator, module: *const Module, source: Source, receipt: *const Receipt, root: N, output: *const std.DynamicBitSet, original: *const std.DynamicBitSet, producer: ?*const @import("../transformer/transformer.zig").Transformer) !?Proof {
    const tree = if (module.ast) |*value| value else return null;
    const sem = if (module.semantic) |*value| value else return null;
    if (!present(tree, root)) return null;
    var result: Proof = .{ .module = module, .semantic = sem };
    var transferred = false;
    defer if (!transferred) result.deinit(a);
    // Most modules have no detached class-self owners. Avoid history replay,
    // source indexes and declaration/reference scans on that common path.
    var needed = false;
    var current = sem.class_self_symbol_map.keyIterator();
    while (current.next()) |raw| if (raw.* >= output.capacity() or !output.isSet(raw.*)) {
        needed = true;
        break;
    };
    if (!needed) {
        transferred = true;
        return result;
    }
    if (!receipt.matches(module, source) or
        (source.semantic.owner_token != .unassigned and source.semantic.owner_token != sem.owner_token) or
        source.tree.source.ptr != tree.source.ptr or source.tree.source.len != tree.source.len) return null;

    var index = try History.validateAndIndex(a, tree, sem.scopes, &sem.scope_owner_map, &sem.scope_history, null);
    defer index.deinit(a);
    if (!index.valid) return null;
    var owners: std.AutoHashMapUnmanaged(u32, History.OwnerBinding) = .empty;
    defer owners.deinit(a);
    for (source.semantic.scope_history.source_owners) |owner| {
        const entry = try owners.getOrPut(a, @backingInt(owner.owner.node));
        if (entry.found_existing) return null;
        entry.value_ptr.* = owner;
    }
    var by_node: std.AutoHashMapUnmanaged(u32, Class) = .empty;
    defer by_node.deinit(a);
    var by_scope: std.AutoHashMapUnmanaged(u32, Class) = .empty;
    defer by_scope.deinit(a);
    var entries = source.semantic.class_self_symbol_map.iterator();
    while (entries.next()) |entry| {
        const raw = entry.key_ptr.*;
        const sid = entry.value_ptr.*;
        if (raw >= source.tree.nodes.items.len or sid >= source.semantic.symbols.items.len or sid >= sem.symbols.items.len) return null;
        const node = source.tree.nodes.items[raw];
        if ((node.tag != .class_declaration and node.tag != .class_expression) or !source.tree.hasExtra(node.data.extra, ast.ClassExtra.body)) return null;
        const owner = owners.get(raw) orelse return null;
        const symbol = source.semantic.symbols.items[sid];
        if (symbol.kind != .class_decl or symbol.scope_id != owner.scope or symbol.origin_scope != owner.scope or
            owner.scope.isNone() or owner.scope.toIndex() >= source.semantic.scopes.len or
            source.semantic.scopes[owner.scope.toIndex()].kind != .class_body or !source.semantic.scopes[owner.scope.toIndex()].is_strict or
            source.semantic.scope_owner_map.get(raw) != @as(?u32, @backingInt(owner.scope))) return null;
        const captured = (try History.Owner.capture(source.tree, @fromBackingInt(raw))) orelse return null;
        if (!std.meta.eql(captured, owner.owner)) return null;
        const record: Class = .{ .node = @fromBackingInt(raw), .name = source.tree.readExtraNode(node.data.extra, ast.ClassExtra.name), .body = source.tree.readExtraNode(node.data.extra, ast.ClassExtra.body), .scope = owner.scope, .sid = sid };
        if (owner.edges.body != record.body or !live(original, record.node) or by_scope.contains(@backingInt(record.scope))) return null;
        try by_node.put(a, raw, record);
        try by_scope.put(a, @backingInt(record.scope), record);
    }
    // Anonymous const classes have no source inner-self SID. The existing
    // inferred-name producer creates one on a copied owner. Record only that
    // exact const declarator -> anonymous initializer edge from the input AST.
    var inferred: std.AutoHashMapUnmanaged(u32, Class) = .empty;
    defer inferred.deinit(a);
    for (source.tree.nodes.items, 0..) |declaration, raw| {
        if (!live(original, @fromBackingInt(@as(u32, @intCast(raw)))) or declaration.tag != .variable_declaration or
            source.tree.variableDeclarationKind(declaration) != .@"const") continue;
        const start = source.tree.readExtra(declaration.data.extra, 1);
        const len = source.tree.readExtra(declaration.data.extra, 2);
        for (source.tree.extra_data.items[start..][0..len]) |declarator_raw| {
            const declarator = source.tree.nodes.items[declarator_raw];
            if (declarator.tag != .variable_declarator) continue;
            const binding = source.tree.readExtraNode(declarator.data.extra, 0);
            const init = source.tree.readExtraNode(declarator.data.extra, 2);
            if (!present(source.tree, binding) or !present(source.tree, init) or
                source.tree.getNode(binding).tag != .binding_identifier) continue;
            const value = source.tree.getNode(init);
            if (value.tag != .class_expression or !source.tree.readExtraNode(value.data.extra, ast.ClassExtra.name).isNone() or
                source.semantic.class_self_symbol_map.contains(@backingInt(init))) continue;
            const owner = owners.get(@backingInt(init)) orelse continue;
            if (source.semantic.scope_owner_map.get(@backingInt(init)) != @as(?u32, @backingInt(owner.scope)) or
                owner.edges.body != source.tree.readExtraNode(value.data.extra, ast.ClassExtra.body) or
                owner.scope.toIndex() >= source.semantic.scopes.len or
                source.semantic.scopes[owner.scope.toIndex()].kind != .class_body) return null;
            const binding_raw = @backingInt(binding);
            if (binding_raw >= source.semantic.symbol_ids.len or source.semantic.symbol_ids[binding_raw] == null) return null;
            const captured = (try History.Owner.capture(source.tree, init)) orelse return null;
            if (!std.meta.eql(captured, owner.owner) or inferred.contains(@backingInt(owner.scope))) return null;
            try inferred.put(a, @backingInt(owner.scope), .{ .node = init, .body = owner.edges.body, .name = binding, .scope = owner.scope, .sid = source.semantic.symbol_ids[binding_raw].? });
        }
    }
    var inferred_copies: std.AutoHashMapUnmanaged(u32, Class) = .empty;
    defer inferred_copies.deinit(a);
    if (producer) |actual| {
        // runCandidate publishes the owned Transformer AST by header copy.
        // Bind this transient producer to that exact backing, not the address
        // of the copied Module.ast header.
        if (actual.ast.nodes.items.ptr != tree.nodes.items.ptr or actual.ast.nodes.items.len != tree.nodes.items.len or
            actual.ast.extra_data.items.ptr != tree.extra_data.items.ptr or actual.ast.extra_data.items.len != tree.extra_data.items.len or
            actual.ast.source.ptr != tree.source.ptr or actual.ast.source.len != tree.source.len or
            actual.ast.transformed_root != tree.transformed_root or
            actual.parser_node_count < source.tree.nodes.items.len or actual.parser_node_count > tree.nodes.items.len) return null;
        var copies = actual.scope_owner_origins.iterator();
        while (copies.next()) |copy| {
            if (copy.key_ptr.* == copy.value_ptr.* or !sem.class_self_symbol_map.contains(copy.key_ptr.*)) continue;
            const original_owner = owners.get(copy.value_ptr.*) orelse continue;
            // Some producers (using's declaration-to-expression handoff)
            // retain an intermediate class-self carrier which is not the
            // final History owner. Its authority is the actual Transformer's
            // exact source-origin and owned-scope pair, not a scope search.
            if (by_node.get(copy.value_ptr.*)) |known| {
                if (known.node != original_owner.owner.node or known.scope != original_owner.scope or
                    actual.transformed_scope_owner_map.get(copy.key_ptr.*) != @as(?u32, @backingInt(known.scope)) or
                    copy.key_ptr.* >= tree.nodes.items.len) return null;
                const tag = tree.nodes.items[copy.key_ptr.*].tag;
                if (tag == .class_expression or tag == .class_declaration) try by_node.put(a, copy.key_ptr.*, known);
            }
            const anonymous = inferred.get(@backingInt(original_owner.scope)) orelse continue;
            if (@backingInt(anonymous.node) != copy.value_ptr.*) return null;
            if (actual.transformed_scope_owner_map.get(copy.key_ptr.*) != @as(?u32, @backingInt(anonymous.scope))) return null;
            try inferred_copies.put(a, copy.key_ptr.*, anonymous);
        }
    }
    // Only an explicit validated owner-copy event extends an original class
    // node's authority. A same-spelled owner elsewhere is never selected.
    if (source.semantic.scope_history.events.len > sem.scope_history.events.len) return null;
    for (sem.scope_history.events[source.semantic.scope_history.events.len..]) |event| {
        if (event.kind != .owner) continue;
        const after = event.owner_after orelse continue;
        if (inferred.get(@backingInt(event.scope))) |anonymous| {
            if (after.tag == .class_expression) try inferred_copies.put(a, @backingInt(after.node), anonymous);
        }
        const record = by_scope.get(@backingInt(event.scope)) orelse continue;
        if (after.tag != .class_declaration and after.tag != .class_expression) continue;
        try by_node.put(a, @backingInt(after.node), record);
    }
    // Index physical output declaration rows once, not once per class.
    var declarations: std.AutoHashMapUnmanaged(u32, N) = .empty;
    defer declarations.deinit(a);
    for (sem.references) |row| {
        if (!row.flags.declare or !live(output, row.declaration_node_index)) continue;
        const sid = @backingInt(row.symbol_id);
        if (sid >= sem.symbols.items.len) return null;
        const symbol = sem.symbols.items[sid];
        const raw = @backingInt(row.declaration_node_index);
        var binding: N = row.declaration_node_index;
        if (raw >= sem.symbol_ids.len or sem.symbol_ids[raw] != sid or tree.nodes.items[raw].tag != .binding_identifier or
            symbol.scope_id.isNone() or symbol.scope_id.toIndex() >= sem.scope_maps.len or row.scope_id != symbol.scope_id or
            row.flags.read or row.flags.write or row.flags.type_context or row.flags.value_as_type or
            sem.scope_maps[symbol.scope_id.toIndex()].get(tree.identifierNameText(tree.nodes.items[raw])) != @as(?usize, sid)) binding = .none;
        const entry = try declarations.getOrPut(a, sid);
        if (entry.found_existing) binding = .none;
        entry.value_ptr.* = binding;
    }
    const OutputOwners = struct { function: N = .none, class: N = .none, ambiguous: bool = false };
    var output_owners: std.AutoHashMapUnmanaged(u32, OutputOwners) = .empty;
    defer output_owners.deinit(a);
    var current_owner_rows = sem.scope_owner_map.iterator();
    while (current_owner_rows.next()) |owner| {
        const raw = owner.key_ptr.*;
        if (raw >= tree.nodes.items.len or raw >= output.capacity() or !output.isSet(raw)) continue;
        const tag = tree.nodes.items[raw].tag;
        if (tag != .class_declaration and tag != .class_expression and tag != .function_declaration and tag != .function_expression) continue;
        const entry = try output_owners.getOrPut(a, owner.value_ptr.*);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const selected = if (tag == .class_declaration or tag == .class_expression) &entry.value_ptr.class else &entry.value_ptr.function;
        if (!selected.isNone()) entry.value_ptr.ambiguous = true;
        selected.* = @fromBackingInt(raw);
    }
    var current_rows = try anchorlessRows(a, sem);
    defer current_rows.deinit(a);
    var initial_rows = try anchorlessRows(a, source.semantic);
    defer initial_rows.deinit(a);
    if (producer) |actual| {
        var births = actual.wrapper_class_self_bindings.iterator();
        while (births.next()) |entry| {
            const birth = entry.value_ptr.*;
            if (entry.key_ptr.* != birth.source_class) return null;
            const raw = @backingInt(birth.source_class);
            const origin = actual.scope_owner_origins.get(raw) orelse raw;
            const owner = owners.get(origin) orelse return null;
            if (origin >= source.tree.nodes.items.len or !live(original, @fromBackingInt(origin)) or
                birth.symbol < source.semantic.symbols.items.len or birth.symbol >= sem.symbols.items.len or
                sem.class_self_symbol_map.get(raw) != @as(?u32, birth.symbol) or
                !live(output, birth.wrapper) or !live(output, birth.declaration) or !live(output, birth.binding)) return null;
            const source_class = source.tree.nodes.items[origin];
            if ((source_class.tag != .class_expression and source_class.tag != .class_declaration) or
                owner.owner.tag != source_class.tag or owner.edges.body != source.tree.readExtraNode(source_class.data.extra, ast.ClassExtra.body) or
                source.semantic.scope_owner_map.get(origin) != @as(?u32, @backingInt(owner.scope))) return null;
            const source_name = source.tree.readExtraNode(source_class.data.extra, ast.ClassExtra.name);
            if (!source_name.isNone()) {
                const source_self = source.semantic.class_self_symbol_map.get(origin) orelse return null;
                if (source_self >= source.semantic.symbols.items.len) return null;
                const before = source.semantic.symbols.items[source_self];
                const rows = initial_rows.get(source_self) orelse return null;
                if (before.kind != .class_decl or before.scope_id != owner.scope or before.origin_scope != owner.scope or
                    before.reference_count != 0 or before.write_count != 0 or rows.total != 1 or
                    (rows.anchorless != 1 and rows.physical_declaration != source_name) or
                    !actual.options.minify_syntax or actual.options.keep_names) return null;
            } else if (source.semantic.class_self_symbol_map.contains(origin)) return null;
            const declaration = tree.getNode(birth.declaration);
            const wrapper = tree.getNode(birth.wrapper);
            const symbol = sem.symbols.items[birth.symbol];
            if (declaration.tag != .class_declaration or wrapper.tag != .arrow_function_expression or
                tree.readExtraNode(declaration.data.extra, ast.ClassExtra.name) != birth.binding or
                @backingInt(birth.binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(birth.binding)] != birth.symbol or
                declarations.get(birth.symbol) != @as(?N, birth.binding) or
                symbol.kind != .class_decl or symbol.scope_id != birth.wrapper_scope or symbol.origin_scope != birth.wrapper_scope or
                sem.scope_owner_map.get(@backingInt(birth.wrapper)) != @as(?u32, @backingInt(birth.wrapper_scope)) or
                sem.scope_owner_map.get(@backingInt(birth.declaration)) != @as(?u32, @backingInt(owner.scope)) or
                birth.wrapper_scope.toIndex() >= sem.scopes.len or owner.scope.toIndex() >= sem.scopes.len or
                sem.scopes[birth.wrapper_scope.toIndex()].kind != .function or
                sem.scopes[owner.scope.toIndex()].kind != .class_body or sem.scopes[owner.scope.toIndex()].parent != birth.wrapper_scope or
                actual.scope_owner_origins.get(@backingInt(birth.declaration)) != @as(?u32, origin) or
                !wrapperDirectlyOwnsDeclaration(tree, birth.wrapper, birth.declaration)) return null;
            if (!try result.add(a, birth.source_class, birth.symbol)) return null;
        }
    }
    var self_entries = sem.class_self_symbol_map.iterator();
    while (self_entries.next()) |entry| {
        if (entry.key_ptr.* < output.capacity() and output.isSet(entry.key_ptr.*)) continue;
        const record = by_node.get(entry.key_ptr.*) orelse {
            const anonymous = inferred_copies.get(entry.key_ptr.*) orelse continue;
            const sid = entry.value_ptr.*;
            if (sid < source.semantic.symbols.items.len or sid >= sem.symbols.items.len or !present(tree, @fromBackingInt(entry.key_ptr.*))) return null;
            const named = tree.nodes.items[entry.key_ptr.*];
            if (named.tag != .class_expression) return null;
            const name = tree.readExtraNode(named.data.extra, ast.ClassExtra.name);
            const symbol = sem.symbols.items[sid];
            if (!present(tree, name) or tree.getNode(name).tag != .binding_identifier or
                tree.readExtraNode(named.data.extra, ast.ClassExtra.body) != anonymous.body or
                @backingInt(name) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(name)] != sid or
                !symbol.decl_flags.preserve_class_name or
                (symbol.kind != .class_decl and symbol.kind != .function_decl) or
                declarations.get(sid) == null or declarations.get(sid).?.isNone() or
                !@import("../lexer/scanner.zig").Scanner.identifierNamesEqual(tree.identifierNameText(tree.getNode(name)), source.tree.identifierNameText(source.tree.getNode(anonymous.name)))) return null;
            if (!try result.add(a, @fromBackingInt(entry.key_ptr.*), sid)) return null;
            continue;
        };
        if (record.sid != entry.value_ptr.* or !present(tree, @fromBackingInt(entry.key_ptr.*))) continue;
        const node = tree.nodes.items[entry.key_ptr.*];
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const symbol = sem.symbols.items[record.sid];
        const before = source.semantic.symbols.items[record.sid];
        const output_declaration: N = declarations.get(record.sid) orelse .none;
        var native_class_copy = false;
        if (output_owners.get(@backingInt(record.scope))) |actual| {
            if (!actual.ambiguous and !actual.class.isNone()) {
                const current_class = tree.getNode(actual.class);
                const current_record = by_node.get(@backingInt(actual.class));
                const name = tree.readExtraNode(current_class.data.extra, ast.ClassExtra.name);
                const body = tree.readExtraNode(current_class.data.extra, ast.ClassExtra.body);
                const same_native_frame = current_record != null and current_record.?.sid == record.sid and
                    current_record.?.scope == record.scope and symbol.scope_id == record.scope and symbol.origin_scope == record.scope and
                    sem.scopes[record.scope.toIndex()].kind == .class_body and sem.scopes[record.scope.toIndex()].is_strict and
                    present(tree, body) and tree.getNode(body).tag == .class_body;
                const retained_name = present(tree, name) and tree.getNode(name).tag == .binding_identifier and
                    present(source.tree, record.name) and @import("../lexer/scanner.zig").Scanner.identifierNamesEqual(tree.identifierNameText(tree.getNode(name)), source.tree.identifierNameText(source.tree.getNode(record.name)));
                const before_rows = initial_rows.get(record.sid) orelse RowSummary{};
                const after_rows = current_rows.get(record.sid) orelse RowSummary{};
                // The existing syntax minifier can remove an unused named
                // class-expression name. Its source-only self cell remains
                // anchorless metadata, never an output value/lookup authority.
                const erased_unused_name = name.isNone() and current_class.tag == .class_expression and
                    source.tree.getNode(record.node).tag == .class_expression and !record.name.isNone() and
                    before.reference_count == 0 and before.write_count == 0 and symbol.reference_count == 0 and symbol.write_count == 0 and
                    before_rows.total == 1 and (before_rows.anchorless == 1 or before_rows.physical_declaration == record.name) and
                    after_rows.total == 1 and after_rows.anchorless == 1;
                native_class_copy = same_native_frame and (retained_name or erased_unused_name);
            }
        }
        if (symbol.kind != before.kind or symbol.decl_flags.is_class != before.decl_flags.is_class or
            (!native_class_copy and (output_declaration.isNone() or
                (symbol.origin_scope != record.scope and symbol.origin_scope != symbol.scope_id)))) continue;
        if (!try result.add(a, @fromBackingInt(entry.key_ptr.*), record.sid)) return null;
    }

    var lowered = (try Worklet.prepare(a, tree, &index, sem.scope_history.lowered_worklet_classes, .{
        .ast_owner = tree,
        .symbols = sem.symbols.items,
        .scopes = sem.scopes,
        .scope_maps = sem.scope_maps,
        .owners = &sem.scope_owner_map,
        .ids = sem.symbol_ids,
        .references = sem.references,
        .class_self_symbols = &sem.class_self_symbol_map,
        .root = root,
        .history_identity = @ptrCast(&sem.scope_history),
    })) orelse return null;
    defer lowered.deinit(a);
    for (sem.scope_history.lowered_worklet_classes) |witness| {
        const record = by_node.get(@backingInt(witness.source.node)) orelse return null;
        if (record.sid != @backingInt(witness.source.self) or record.scope != witness.source.scope or record.body != witness.source.body or
            record.name != witness.source.name or lowered.bridge(witness.target.scope) == null) return null;
        if (!try result.add(a, witness.source.node, @backingInt(witness.source.self)) or
            !try result.add(a, witness.target.node, @backingInt(witness.target.self))) return null;
    }
    // Native retained class copies have no lowered-IIFE witness. Authenticate
    // their original Creator, both class frames, actual factory declaration,
    // current class owner, and physical factory-body containment instead.
    var historical_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer historical_owners.deinit(a);
    for (sem.scope_history.source_owners) |owner| try historical_owners.put(a, @backingInt(owner.owner.node), @backingInt(owner.scope));
    for (sem.scope_history.events) |event| if (event.owner_after) |owner| {
        try historical_owners.put(a, @backingInt(owner.node), @backingInt(event.scope));
    };
    var lowered_creators: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer lowered_creators.deinit(a);
    for (sem.scope_history.lowered_worklet_classes) |witness| try lowered_creators.put(a, witness.creator_index, {});
    for (sem.scope_history.worklet_class_creators, 0..) |creator, creator_index| {
        if (lowered_creators.contains(@intCast(creator_index))) continue;
        const record = by_node.get(@backingInt(creator.source.node)) orelse return null;
        if (record.sid != @backingInt(creator.source.self) or record.scope != creator.source.scope or record.body != creator.source.body or record.name != creator.source.name) return null;
        const graph: Worklet.Graph = .{ .ast_owner = tree, .symbols = sem.symbols.items, .scopes = sem.scopes, .scope_maps = sem.scope_maps, .owners = &sem.scope_owner_map, .ids = sem.symbol_ids, .references = sem.references, .class_self_symbols = &sem.class_self_symbol_map, .root = root, .history_identity = @ptrCast(&sem.scope_history) };
        if (!Worklet.classShape(tree, graph, creator.source) or !Worklet.classShape(tree, graph, creator.target) or
            creator.source.node == creator.target.node or creator.source.scope == creator.target.scope or creator.source.self == creator.target.self or
            creator.source.body == creator.target.body or creator.source.name == creator.target.name) return null;
        const source_frame = index.frameAt(creator.source.scope, creator.epoch) orelse return null;
        const target_frame = index.frameAt(creator.target.scope, creator.epoch) orelse return null;
        const wrapper_frame = index.frameAt(creator.wrapper_scope, creator.epoch) orelse return null;
        if (source_frame.kind != .class_body or target_frame.kind != .class_body or wrapper_frame.kind != .function or
            target_frame.parent != creator.factory_scope or source_frame.parent != wrapper_frame.parent or
            sem.scopes[creator.target.scope.toIndex()].parent != creator.factory_scope or
            historical_owners.get(@backingInt(creator.source.node)) != @as(?u32, @backingInt(creator.source.scope)) or
            historical_owners.get(@backingInt(creator.target.node)) != @as(?u32, @backingInt(creator.target.scope)) or
            historical_owners.get(@backingInt(creator.factory)) != @as(?u32, @backingInt(creator.factory_scope))) return null;
        const factory_id = @backingInt(creator.factory_symbol);
        if (factory_id >= sem.symbols.items.len or sem.symbols.items[factory_id].kind != .function_decl or
            sem.symbols.items[factory_id].scope_id != creator.wrapper_scope or
            !present(tree, creator.factory_binding) or @backingInt(creator.factory_binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(creator.factory_binding)] != factory_id) return null;
        const factory_binding = declarations.get(factory_id) orelse return null;
        if (factory_binding.isNone()) return null;
        const factory_owner = output_owners.get(@backingInt(creator.factory_scope)) orelse return null;
        const class_owner = output_owners.get(@backingInt(creator.target.scope)) orelse return null;
        const actual_factory = factory_owner.function;
        const actual_class = class_owner.class;
        // The class-self registry retains its producer node key across a
        // validated owner copy. Authenticate that copy through the exact
        // target scope's history, rather than requiring a second registry row.
        const class_copy = !actual_class.isNone() and actual_class != creator.target.node and
            historical_owners.get(@backingInt(actual_class)) == @as(?u32, @backingInt(creator.target.scope)) and
            tree.getNode(actual_class).tag == tree.getNode(creator.target.node).tag;
        if (factory_owner.ambiguous or class_owner.ambiguous or
            (!actual_factory.isNone() and tree.readExtraNode(tree.getNode(actual_factory).data.extra, ast.FunctionExtra.name) != factory_binding) or
            (!actual_class.isNone() and !class_copy and sem.class_self_symbol_map.get(@backingInt(actual_class)) != @as(?u32, @backingInt(creator.target.self)))) return null;
        if (actual_factory.isNone() or actual_class.isNone() or
            !try contains(a, tree, tree.readExtraNode(tree.getNode(actual_factory).data.extra, ast.FunctionExtra.body), actual_class)) return null;
        if (!try result.add(a, creator.source.node, @backingInt(creator.source.self)) or
            !try result.add(a, creator.target.node, @backingInt(creator.target.self))) return null;
    }
    transferred = true;
    return result;
}

test "class sidecar actual source and Worklet pipelines retain ten shapes and two self reads" {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const compat = @import("../transformer/compat.zig");
    const cases = [_]struct { source: []const u8, worklet: bool = false }{
        .{ .source = "class A{read(){return 42}}console.log(new A().read());" },
        .{ .source = "var A=class Named{read(){return 42}};console.log(new A().read());" },
        .{ .source = "const A=class{read(){return 42}};console.log(new A().read());" },
        .{ .source = "class Base{read(){return 40}}class A extends Base{read(){return super.read()+2}}console.log(new A().read());" },
        .{ .source = "class A{static value=42}console.log(A.value);" },
        .{ .source = "class A{#value=42;read(){return this.#value}}console.log(new A().read());" },
        .{ .source = "class A{[Symbol.iterator](){return [42][Symbol.iterator]()}}console.log(Array.from(new A())[0]);" },
        .{ .source = "var Object=7;class A{get value(){return 42}}console.log(new A().value);" },
        .{ .worklet = true, .source = "class A{__workletClass=true;read(){return 42}}var C=typeof A.prototype.read==='function'?A:A();console.log(new C().read());" },
        .{ .worklet = true, .source = "class A{__workletClass=true;read(){return 3}}class B{__workletClass=true;read(){return 39}}var C=typeof A.prototype.read==='function'?A:A();var D=typeof B.prototype.read==='function'?B:B();console.log(new C().read()+new D().read());" },
        .{ .source = "class A{static read(){return A===this?42:0}}console.log(A.read());" },
        .{ .source = "var A=class Inner{read(){return new Inner().constructor===Inner?42:0}};console.log(new A().read());" },
    };
    var failures: usize = 0;
    var attempted: usize = 0;
    for (cases, 0..) |case, case_index| {
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("42\n", native.stdout);
        inline for (.{ .es5, .esnext }) |target| {
            for ([_]bool{ false, true }) |minify| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                try helpers.writeFile(tmp.dir, "entry.cjs", case.source);
                const entry = try helpers.absPath(&tmp, "entry.cjs");
                defer std.testing.allocator.free(entry);
                var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .cjs, .platform = .node, .unsupported = compat.fromESTarget(target), .worklet_transform = case.worklet, .minify_syntax = minify, .minify_identifiers = minify, .minify_whitespace = minify });
                defer bundler.deinit();
                attempted += 1;
                const result = try bundler.bundle(std.testing.io);
                defer result.deinit(std.testing.allocator);
                if (result.hasErrors()) {
                    std.debug.print("class sidecar positive index={d} target={s} min={any} source={s}\n", .{ case_index, @tagName(target), minify, case.source });
                    for (result.diagnostics orelse &.{}) |diag| std.debug.print("class sidecar diagnostic {s}\n", .{diag.message});
                }
                if (result.hasErrors()) {
                    failures += 1;
                    continue;
                }
                const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
                defer std.testing.allocator.free(actual.stdout);
                defer std.testing.allocator.free(actual.stderr);
                if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                    std.debug.print("class sidecar runtime index={d} target={s} min={any} code={s} stderr={s}\n", .{ case_index, @tagName(target), minify, result.output, actual.stderr });
                if (actual.term != .exited or actual.term.exited != 0 or actual.stderr.len != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) failures += 1;
            }
        }
    }
    std.debug.print("CLASS_SIDECAR_MATRIX attempted={d} passed={d} failed={d}\n", .{ attempted, attempted - failures, failures });
    try std.testing.expectEqual(@as(usize, 48), attempted);
    try std.testing.expectEqual(@as(usize, 0), failures);
}
