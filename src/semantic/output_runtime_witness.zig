//! Actual registered output bindings which have no lexical AST declaration.
//! Capture is bound to an installed graph module. A staged Module copy is only
//! a validation target and can never create this source authority.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const module_mod = @import("../bundler/module.zig");
const symbol_mod = @import("symbol.zig");
const scope_mod = @import("scope.zig");
const coverage = @import("../transformer/symbol_coverage.zig");
const NodeIndex = ast_mod.NodeIndex;
const SymbolId = symbol_mod.SymbolId;
const ScopeId = scope_mod.ScopeId;

pub const ReferenceContext = struct {
    node: NodeIndex,
    scope: ScopeId,
    flags: symbol_mod.ReferenceFlags,
    stmt_idx: u32,
    scope_stmt_idx: u32,
};

/// Structural context only. This never selects a SymbolId or performs lookup.
/// Owners, including method keys and named-function frames, use the existing
/// exact scope walk rather than a second approximation of analyzer scopes.
pub fn captureReferenceContexts(a: std.mem.Allocator, ast: *const ast_mod.Ast, root: NodeIndex, scopes: []const scope_mod.Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) !?[]ReferenceContext {
    var traces = try coverage.collectScopeTraces(a, ast, root, scopes, owners);
    defer traces.deinit(a);
    var parents = try coverage.collectParentTraces(a, ast, root);
    defer parents.deinit(a);
    const coordinates = try @import("statement_coordinates.zig").collect(a, ast, root);
    defer a.free(coordinates);
    const nodes = try @import("reference_walk.zig").collectIdentifierReferences(a, ast, root);
    defer a.free(nodes);
    var result: std.ArrayList(ReferenceContext) = .empty;
    defer result.deinit(a);
    for (nodes) |node| {
        const raw = @backingInt(node);
        const trace = traces.get(raw) orelse return null;
        if (!trace.valid or trace.ambiguous or trace.scope_id == null or trace.scope_id.? >= scopes.len) return null;
        const coords = coordinates[raw] orelse return null;
        const item = ast.getNode(node);
        var flags: symbol_mod.ReferenceFlags = if (item.tag == .assignment_target_identifier) .{ .write = true } else .{ .read = true };
        if (parents.get(raw)) |parent| {
            if (parent.ambiguous or parent.parent >= ast.nodes.items.len) return null;
            const p = ast.nodes.items[parent.parent];
            if (p.tag == .update_expression and p.data.unary.operand == node) {
                flags = .{ .read = true, .write = true };
            } else if (p.tag == .assignment_expression and p.data.binary.left == node) {
                const op: @import("../lexer/token.zig").Kind = @fromBackingInt(@intCast(p.data.binary.flags));
                flags = .{ .read = op.isCompoundAssignment(), .write = true };
            }
        }
        try result.append(a, .{ .node = node, .scope = @fromBackingInt(trace.scope_id.?), .flags = flags, .stmt_idx = coords.stmt_idx, .scope_stmt_idx = coords.scope_stmt_idx });
    }
    return try result.toOwnedSlice(a);
}

pub const Role = enum(u32) {
    cjs_exports_parameter,
    cjs_module_parameter,
    module_init,
    module_exports,
    module_require,
    cjs_factory,
    cjs_internal,
    esm_factory,
    esm_internal,
    to_binary,
    interop_helper,
    interop_internal,
    hmr_internal,
    require_shim,
    _,
};

/// These are template selection facts, not inferred JavaScript semantics.
/// Normal output uses an ordinary callback member invoked unbound; minified
/// output chooses arrow/function exactly as the emitter's unsupported.arrow.
pub const EmitAbi = struct {
    minify_whitespace: bool,
    unsupported_arrow: bool,
    unsupported_object_extensions: bool,
    callback: enum { ordinary_method, ordinary_property_function, arrow, ordinary_function },
    callback_invocation: enum { unbound } = .unbound,
    loader: enum { arrow, ordinary_function },
};

pub const Entry = struct {
    symbol: SymbolId,
    before: symbol_mod.Symbol,
    role: Role,
    slot: u16 = 0,
};

pub const Wrapper = struct {
    program: NodeIndex,
    scope: ScopeId,
    exports: SymbolId,
    module: SymbolId,
    scope_before: scope_mod.Scope,
    program_scope_before: scope_mod.Scope,
};

pub const Source = struct {
    graph: *const @import("../bundler/graph.zig").ModuleGraph,
    module: *const module_mod.Module,
    ast: *const ast_mod.Ast,
    owner: module_mod.SemanticOwnerToken,
    nodes: []const ast_mod.Node,
    ids: []const ?u32,
    symbols: []const symbol_mod.Symbol,
    scopes: []const scope_mod.Scope,
    references: []const symbol_mod.Reference,
    entries: []const Entry,
    wrapper: ?Wrapper,
    abi: EmitAbi,
    registration: @import("output_runtime_registration.zig").Domain,
    registration_epoch: u64,

    pub fn deinit(self: *Source, a: std.mem.Allocator) void {
        a.free(self.entries);
        self.entries = &.{};
    }

    /// Revalidate installed source plus the actual staged target. Runtime
    /// fields and source metadata cannot be replaced by a matching spelling.
    pub fn validateTarget(self: *const Source, target: *const module_mod.Module) bool {
        if (self.graph.getModule(self.module.index) != self.module or self.module.ast == null or self.module.semantic == null or
            &self.module.ast.? != self.ast or !ownerBelongsOnlyToModule(self.graph, self.module, self.owner) or self.module.semantic.?.owner_token != self.owner or
            self.ast.nodes.items.ptr != self.nodes.ptr or self.ast.nodes.items.len != self.nodes.len or
            self.module.semantic.?.symbol_ids.ptr != self.ids.ptr or self.module.semantic.?.symbol_ids.len != self.ids.len or
            self.module.semantic.?.symbols.items.ptr != self.symbols.ptr or self.module.semantic.?.symbols.items.len != self.symbols.len or
            self.module.semantic.?.scopes.ptr != self.scopes.ptr or self.module.semantic.?.scopes.len != self.scopes.len or
            self.module.semantic.?.references.ptr != self.references.ptr or self.module.semantic.?.references.len != self.references.len or
            target.index != self.module.index or target.wrap_kind != self.module.wrap_kind or target.ast == null or target.semantic == null or
            target.semantic.?.owner_token != self.owner) return false;
        if (!@import("output_runtime_registration.zig").canUseCandidateBackings(self.graph, self.module, target)) return false;
        const registration = self.graph.output_runtime_registry.lookup(self.module) orelse return false;
        if (self.registration_epoch != self.graph.output_runtime_registry.epoch or !std.meta.eql(self.registration, registration)) return false;
        const options = self.graph.transform_options_base;
        if (self.abi.minify_whitespace != options.minify_whitespace or self.abi.unsupported_arrow != options.unsupported.arrow or
            self.abi.unsupported_object_extensions != options.unsupported.object_extensions or
            self.abi.callback != callbackAbi(options.minify_whitespace, options.unsupported.arrow, options.unsupported.object_extensions) or
            self.abi.loader != (if (!options.minify_whitespace or options.unsupported.arrow) @as(@TypeOf(self.abi.loader), .ordinary_function) else .arrow)) return false;
        if (!runtimeSnapshotAgrees(self.module) or !runtimeSnapshotAgrees(target)) return false;
        inline for (std.meta.tags(Role)) |role| {
            var slot: u16 = 0;
            while (true) : (slot += 1) {
                const before = registeredSymbol(self.module, role, slot);
                if (before != registeredSymbol(target, role, slot)) return false;
                if (before == null) break;
                switch (role) {
                    .cjs_internal, .esm_internal, .interop_helper, .interop_internal, .hmr_internal => {},
                    else => break,
                }
            }
        }
        for (self.entries, 0..) |entry, index| {
            for (self.entries[0..index]) |prior| if (prior.symbol == entry.symbol or (prior.role == entry.role and prior.slot == entry.slot)) return false;
            const raw = @backingInt(entry.symbol);
            if (raw >= self.module.semantic.?.symbols.items.len or raw >= target.semantic.?.symbols.items.len or
                registeredSymbol(self.module, entry.role, entry.slot) != entry.symbol or registeredSymbol(target, entry.role, entry.slot) != entry.symbol or
                !validEntryBirth(self.module, entry) or !validEntryBirth(target, entry) or
                !@import("source_owned_retirement.zig").equalSymbol(self.module.semantic.?.symbols.items[raw], entry.before)) return false;
            var expected = entry.before;
            const current = target.semantic.?.symbols.items[raw];
            // Wrapper frequencies are represented by actual Reference rows;
            // Exact recomputes them after the transaction removes dead uses.
            if (entry.role == .cjs_exports_parameter or entry.role == .cjs_module_parameter) {
                expected.reference_count = current.reference_count;
                expected.write_count = current.write_count;
            }
            if (!@import("source_owned_retirement.zig").equalSymbol(expected, current)) return false;
        }
        if (self.wrapper) |wrapper| {
            if (!wrapperAgrees(self.module, wrapper) or !wrapperAgrees(target, wrapper) or
                self.module.semantic.?.scopes[0].symbol_count != wrapper.program_scope_before.symbol_count) return false;
            var expected_count: usize = wrapper.program_scope_before.symbol_count;
            var retired = target.semantic.?.source_owned_retirements.iterator();
            while (retired.next()) |entry| {
                if (self.module.semantic.?.source_owned_retirements.contains(entry.key_ptr.*) or entry.value_ptr.before.scope_id != @as(ScopeId, @fromBackingInt(@as(u32, 0)))) continue;
                if (expected_count == 0) return false;
                expected_count -= 1;
            }
            if (target.semantic.?.scopes[0].symbol_count != expected_count) return false;
        }
        return true;
    }
};

pub const QueryContext = struct {
    ast: *const ast_mod.Ast,
    symbols: []const symbol_mod.Symbol,
    symbol_ids: []const ?u32,
    scopes: []const scope_mod.Scope,
    scope_maps: []const std.StringHashMapUnmanaged(usize),
    scope_owners: *const std.AutoHashMapUnmanaged(u32, u32),
    references: []const symbol_mod.Reference,
    helper_scope_map: *const std.StringHashMapUnmanaged(usize),
    helper_reference_nodes: []const u32,
    retirements: *const @import("source_owned_retirement.zig").Map,
    scope_history: *const @import("scope_frame_history.zig").History,
    provenance: *const @import("node_scope_provenance.zig").Map,
    class_self_symbols: *const std.AutoHashMapUnmanaged(u32, u32),
    namespace_member_owners: *const std.AutoHashMapUnmanaged(u32, u32),
    namespace_declaration_owners: *const std.AutoHashMapUnmanaged(u32, u32),
};

pub const Target = struct {
    source: *const Source,
    module: *const module_mod.Module,

    pub fn validatesContext(self: Target, context: QueryContext) bool {
        if (!self.validates(context.ast, context.symbols, context.symbol_ids)) return false;
        const sem = &self.module.semantic.?;
        const helpers = if (self.module.transform_cache) |cache| cache.helper_ref_nodes else &.{};
        return sem.scopes.ptr == context.scopes.ptr and sem.scopes.len == context.scopes.len and
            sem.scope_maps.ptr == context.scope_maps.ptr and sem.scope_maps.len == context.scope_maps.len and
            &sem.scope_owner_map == context.scope_owners and sem.references.ptr == context.references.ptr and sem.references.len == context.references.len and
            &sem.helper_scope_map == context.helper_scope_map and &sem.source_owned_retirements == context.retirements and
            &sem.scope_history == context.scope_history and
            &sem.node_scope_provenance == context.provenance and &sem.class_self_symbol_map == context.class_self_symbols and
            &sem.namespace_member_owners == context.namespace_member_owners and &sem.namespace_declaration_owners == context.namespace_declaration_owners and
            helpers.len == context.helper_reference_nodes.len and (helpers.len == 0 or helpers.ptr == context.helper_reference_nodes.ptr);
    }

    pub fn validates(self: Target, ast: *const ast_mod.Ast, symbols: []const symbol_mod.Symbol, ids: []const ?u32) bool {
        return self.source.validateTarget(self.module) and &self.module.ast.? == ast and
            self.module.semantic.?.symbols.items.ptr == symbols.ptr and self.module.semantic.?.symbols.items.len == symbols.len and
            self.module.semantic.?.symbol_ids.ptr == ids.ptr and self.module.semantic.?.symbol_ids.len == ids.len;
    }
};

fn ownerBelongsOnlyToModule(graph: *const @import("../bundler/graph.zig").ModuleGraph, module: *const module_mod.Module, owner: module_mod.SemanticOwnerToken) bool {
    const registered = graph.output_runtime_registry.lookup(module) orelse return false;
    return owner != .unassigned and registered.owner == owner;
}

fn callbackAbi(min: bool, no_arrow: bool, no_methods: bool) @TypeOf(@as(EmitAbi, undefined).callback) {
    return if (!min) (if (no_methods) .ordinary_property_function else .ordinary_method) else if (no_arrow) .ordinary_function else .arrow;
}

fn registeredSymbol(m: *const module_mod.Module, role: Role, slot: u16) ?SymbolId {
    return switch (role) {
        .cjs_exports_parameter => m.cjs_wrapper_exports_parameter_symbol,
        .cjs_module_parameter => m.cjs_wrapper_module_parameter_symbol,
        .module_init => m.init_symbol,
        .module_exports => m.exports_symbol,
        .module_require => m.require_symbol,
        .cjs_factory => m.cjs_runtime_factory_symbol,
        .esm_factory => m.esm_runtime_factory_symbol,
        .to_binary => m.to_binary_runtime_symbol,
        .require_shim => m.require_shim_local_symbol,
        .cjs_internal => groupSlot(m.cjs_runtime_internal_symbols, slot),
        .esm_internal => groupSlot(m.esm_runtime_internal_symbols, slot),
        .interop_helper => groupSlot(m.esm_interop_runtime_helper_symbols, slot),
        .interop_internal => groupSlot(m.esm_interop_runtime_internal_symbols, slot),
        .hmr_internal => groupSlot(m.hmr_runtime_internal_symbols, slot),
        else => null,
    };
}

fn groupSlot(group: anytype, slot: u16) ?SymbolId {
    const value = group orelse return null;
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names, 0..) |field, index| {
        if (slot == index) return @field(value, field);
    }
    return null;
}

fn validEntryBirth(m: *const module_mod.Module, entry: Entry) bool {
    const sem = if (m.semantic) |*value| value else return false;
    const raw = @backingInt(entry.symbol);
    if (raw >= sem.symbols.items.len) return false;
    const symbol = sem.symbols.items[raw];
    const empty = @import("../lexer/token.zig").Span.EMPTY;
    if (symbol.synthetic_name.len == 0 or !std.meta.eql(symbol.name, empty) or
        !std.meta.eql(symbol.declaration_span, empty) or !std.meta.eql(symbol.decl_flags, symbol.kind.declFlags())) return false;
    if (symbol.const_kind != .none or symbol.requires_uppercase_first_char or symbol.synthetic_owner_id != null or
        !std.meta.eql(symbol.annex_b_alias, @as(symbol_mod.AnnexBFunctionAlias, .{})) or
        !std.meta.eql(symbol.parameter_copy, @as(symbol_mod.ParameterBodyVarCopy, .{})) or
        !std.meta.eql(symbol.binding_instantiation, @as(symbol_mod.BindingInstantiation, .{}))) return false;
    if (entry.role == .cjs_exports_parameter or entry.role == .cjs_module_parameter) {
        const is_exports = entry.role == .cjs_exports_parameter;
        return m.wrap_kind == .cjs and symbol.kind == .parameter and symbol.synthetic_kind == (if (is_exports) @as(symbol_mod.SyntheticKind, .cjs_wrapper_exports_parameter) else .cjs_wrapper_module_parameter) and
            !symbol.scope_id.isNone() and symbol.scope_id == symbol.origin_scope and
            std.mem.eql(u8, symbol.synthetic_name, if (is_exports) "exports" else "module");
    }
    // Raw output declarations have no source lexical storage or edges. Their
    // exact slot and protocol labels come from the existing registered ABI.
    if (!symbol.scope_id.isNone() or !symbol.origin_scope.isNone()) return false;
    const names = @import("../runtime_helper_names.zig");
    return switch (entry.role) {
        .module_init => m.wrap_kind != .none and symbol.kind == .function_decl and symbol.synthetic_kind == .esm_init,
        .module_require => m.wrap_kind == .cjs and symbol.kind == .function_decl and symbol.synthetic_kind == .cjs_require,
        .module_exports => m.wrap_kind != .none and symbol.kind == .variable_var and symbol.synthetic_kind == .cjs_exports,
        .cjs_factory => symbol.kind == .variable_var and symbol.synthetic_kind == .cjs_runtime_factory and std.mem.eql(u8, symbol.synthetic_name, "__commonJS"),
        .esm_factory => symbol.kind == .variable_var and symbol.synthetic_kind == .bundler_runtime_helper and std.mem.eql(u8, symbol.synthetic_name, "__esm"),
        .to_binary => symbol.kind == .variable_var and symbol.synthetic_kind == .bundler_runtime_helper and std.mem.eql(u8, symbol.synthetic_name, "__toBinary"),
        .require_shim => symbol.kind == .import_binding and symbol.synthetic_kind == .require_shim_local and std.mem.eql(u8, symbol.synthetic_name, "createRequire"),
        .cjs_internal => blk: {
            const protocol: names.CjsRuntimeInternalNames = .{};
            inline for (@typeInfo(module_mod.CjsRuntimeInternalSymbolIds).@"struct".field_names, 0..) |field, index| {
                if (entry.slot == index) {
                    const kind: symbol_mod.SymbolKind = if (comptime std.mem.eql(u8, field, "catch_parameter")) .catch_binding else if (comptime std.mem.eql(u8, field, "require_function")) .function_decl else .parameter;
                    break :blk symbol.kind == kind and symbol.synthetic_kind == .cjs_runtime_internal_local and std.mem.eql(u8, symbol.synthetic_name, @field(protocol, field));
                }
            }
            break :blk false;
        },
        .esm_internal => blk: {
            const protocol: names.EsmRuntimeInternalNames = .{};
            inline for (@typeInfo(module_mod.EsmRuntimeInternalSymbolIds).@"struct".field_names, 0..) |field, index| {
                if (entry.slot == index) {
                    const kind: symbol_mod.SymbolKind = if (comptime std.mem.eql(u8, field, "catch_parameter")) .catch_binding else if (comptime std.mem.eql(u8, field, "init_function")) .function_decl else if (comptime std.mem.eql(u8, field, "factory_local")) .variable_var else .parameter;
                    break :blk symbol.kind == kind and symbol.synthetic_kind == .esm_runtime_internal_local and std.mem.eql(u8, symbol.synthetic_name, @field(protocol, field));
                }
            }
            break :blk false;
        },
        .interop_helper => if (m.esm_interop_runtime_helper_symbols) |ids| module_mod.validEsmInteropHelperIds(ids, sem.symbols.items) else false,
        .interop_internal => if (m.esm_interop_runtime_internal_symbols) |ids| module_mod.validEsmInteropInternalIds(ids, sem.symbols.items) else false,
        .hmr_internal => if (m.hmr_runtime_internal_symbols) |ids| module_mod.validHmrRuntimeIds(ids, sem.symbols.items) else false,
        else => false,
    };
}

fn runtimeSnapshotAgrees(m: *const module_mod.Module) bool {
    const sem = m.semantic orelse return false;
    const snapshot = sem.runtime_identities orelse return m.cjs_runtime_factory_symbol == null and m.esm_runtime_factory_symbol == null and m.to_binary_runtime_symbol == null and m.cjs_runtime_internal_symbols == null and m.esm_runtime_internal_symbols == null and m.esm_interop_runtime_helper_symbols == null and m.esm_interop_runtime_internal_symbols == null and m.hmr_runtime_internal_symbols == null;
    return std.meta.eql(snapshot.*, module_mod.RuntimeIdentitySnapshot{
        .cjs_factory = m.cjs_runtime_factory_symbol,
        .cjs_internal = m.cjs_runtime_internal_symbols,
        .esm_factory = m.esm_runtime_factory_symbol,
        .esm_internal = m.esm_runtime_internal_symbols,
        .to_binary = m.to_binary_runtime_symbol,
        .interop_helpers = m.esm_interop_runtime_helper_symbols,
        .interop_internal = m.esm_interop_runtime_internal_symbols,
        .hmr_internal = m.hmr_runtime_internal_symbols,
    });
}

fn wrapperAgrees(m: *const module_mod.Module, w: Wrapper) bool {
    const ast = if (m.ast) |*value| value else return false;
    const sem = if (m.semantic) |*value| value else return false;
    const raw = w.scope.toIndex();
    if (m.wrap_kind != .cjs or sem.scopes.len == 0 or sem.scope_maps.len != sem.scopes.len or raw >= sem.scopes.len or raw == 0 or
        w.program.isNone() or @backingInt(w.program) >= ast.nodes.items.len or ast.getNode(w.program).tag != .program or
        sem.scope_owner_map.get(@backingInt(w.program)) != 0 or sem.scopes[0].parent != w.scope or
        sem.scopes[raw].kind != .function or !sem.scopes[raw].parent.isNone() or sem.scopes[raw].symbol_count != 2 or
        sem.scope_maps[raw].count() != 2 or sem.scope_maps[raw].get("exports") != @as(?usize, @backingInt(w.exports)) or
        sem.scope_maps[raw].get("module") != @as(?usize, @backingInt(w.module)) or w.exports == w.module or
        m.cjs_wrapper_exports_parameter_symbol != w.exports or m.cjs_wrapper_module_parameter_symbol != w.module) return false;
    if (!std.meta.eql(sem.scopes[raw], w.scope_before)) return false;
    var expected_root = w.program_scope_before;
    // Only exact newly retired source bindings can reduce the program's
    // declaration count. All other root flags retain their captured meaning.
    expected_root.symbol_count = sem.scopes[0].symbol_count;
    if (!std.meta.eql(sem.scopes[0], expected_root)) return false;
    var owners = sem.scope_owner_map.valueIterator();
    while (owners.next()) |owner| if (owner.* == raw) return false;
    for ([_]SymbolId{ w.exports, w.module }, [_]symbol_mod.SyntheticKind{ .cjs_wrapper_exports_parameter, .cjs_wrapper_module_parameter }) |sid, kind| {
        if (@backingInt(sid) >= sem.symbols.items.len) return false;
        const symbol = sem.symbols.items[@backingInt(sid)];
        if (symbol.scope_id != w.scope or symbol.origin_scope != w.scope or symbol.kind != .parameter or symbol.synthetic_kind != kind or
            !symbol.decl_flags.is_parameter or !std.meta.eql(symbol.name, @import("../lexer/token.zig").Span.EMPTY) or !std.meta.eql(symbol.declaration_span, @import("../lexer/token.zig").Span.EMPTY)) return false;
    }
    return true;
}

pub fn capture(a: std.mem.Allocator, graph: *const @import("../bundler/graph.zig").ModuleGraph, m: *const module_mod.Module) !?Source {
    if (!graph.wrapper_symbols_registered or graph.getModule(m.index) != m or m.ast == null or m.semantic == null or !runtimeSnapshotAgrees(m)) return null;
    const ast = &m.ast.?;
    const sem = &m.semantic.?;
    if (ast.nodes.items.len == 0 or !ownerBelongsOnlyToModule(graph, m, sem.owner_token)) return null;
    const registration = graph.output_runtime_registry.lookup(m) orelse return null;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(a);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(a);
    // All field slots are fixed by the existing first-class runtime registry.
    inline for (std.meta.tags(Role)) |role| {
        var slot: u16 = 0;
        while (registeredSymbol(m, role, slot)) |sid| : (slot += 1) {
            if (sid.isNone() or @backingInt(sid) >= sem.symbols.items.len) return null;
            const found = try seen.getOrPut(a, @backingInt(sid));
            if (found.found_existing) return null;
            const entry: Entry = .{ .symbol = sid, .before = sem.symbols.items[@backingInt(sid)], .role = role, .slot = slot };
            if (!validEntryBirth(m, entry)) return null;
            try entries.append(a, entry);
            switch (role) {
                .cjs_internal, .esm_internal, .interop_helper, .interop_internal, .hmr_internal => {},
                else => break,
            }
        }
    }
    var wrapper: ?Wrapper = null;
    if (m.wrap_kind == .cjs) {
        if (sem.scopes.len == 0 or sem.scopes[0].parent.isNone() or sem.scopes[0].parent.toIndex() >= sem.scopes.len) return null;
        wrapper = .{ .scope_before = sem.scopes[sem.scopes[0].parent.toIndex()], .program_scope_before = sem.scopes[0], .program = ast.transformed_root orelse @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))), .scope = sem.scopes[0].parent, .exports = m.cjs_wrapper_exports_parameter_symbol orelse return null, .module = m.cjs_wrapper_module_parameter_symbol orelse return null };
        if (!wrapperAgrees(m, wrapper.?)) return null;
    }
    const options = graph.transform_options_base;
    const owned_entries = try entries.toOwnedSlice(a);
    const owner = sem.owner_token;
    return .{ .graph = graph, .module = m, .ast = ast, .owner = owner, .nodes = ast.nodes.items, .ids = sem.symbol_ids, .symbols = sem.symbols.items, .scopes = sem.scopes, .references = sem.references, .entries = owned_entries, .wrapper = wrapper, .registration = registration, .registration_epoch = graph.output_runtime_registry.epoch, .abi = .{
        .minify_whitespace = options.minify_whitespace,
        .unsupported_arrow = options.unsupported.arrow,
        .unsupported_object_extensions = options.unsupported.object_extensions,
        .callback = callbackAbi(options.minify_whitespace, options.unsupported.arrow, options.unsupported.object_extensions),
        .loader = if (!options.minify_whitespace or options.unsupported.arrow) .ordinary_function else .arrow,
    } };
}
