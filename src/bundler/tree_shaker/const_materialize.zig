//! Cross-module constant materialization used by tree-shaking.
//!
//! This module owns the pre-shake const propagation and the post-shake numeric
//! worklist. Keeping it separate leaves `tree_shaker.zig` focused on graph
//! reachability and export/include fixpoint logic.

test "const transaction failed preparation preserves original graph publication" {
    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const prepass = @import("../graph/transform_prepass.zig");
    const source = "import { seed } from 'dep';export const live=seed;console.log(live);";
    var failures: usize = 0;
    for (0..128) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        scanner.is_module = true;
        var parser = Parser.init(a, &scanner);
        parser.is_module = true;
        _ = try parser.parse();
        var analyzer = SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "const-transaction.mjs");
        module.source = source;
        module.ast = parser.ast;
        module.parse_arena = &arena;
        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .node_scope_provenance = analyzer.node_scope_provenance,
            .class_self_symbol_map = analyzer.class_self_symbol_map,
            .namespace_member_owners = analyzer.namespace_member_owners,
            .namespace_declaration_owners = analyzer.namespace_declaration_owners,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
            .numeric_const_texts = analyzer.numeric_const_texts,
            .helper_scope_map = analyzer.helper_scope_map,
        };
        var removed: ?NodeIndex = null;
        for (analyzer.references.items) |reference| {
            if (!reference.flags.read or reference.flags.declare or reference.node_index.isNone()) continue;
            const node = module.ast.?.getNode(reference.node_index);
            if (node.tag != .identifier_reference or !std.mem.eql(u8, module.ast.?.getText(node.data.string_ref), "seed")) continue;
            removed = reference.node_index;
            module.ast.?.nodes.items[@backingInt(reference.node_index)] = .{
                .tag = .numeric_literal,
                .span = try module.ast.?.addString("7"),
                .data = .{ .none = 0 },
            };
            break;
        }
        const materialized = removed orelse return error.MissingMaterializedReference;
        const before = module.semantic.?;
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        const context = .{
            .allocator = a,
            .defines = &[_]@import("../../parser/scan_results.zig").DefineEntry{},
            .wrapper_symbols_registered = false,
            .wrap_kinds_finalized = true,
            .transform_options_base = .{ .minify_syntax = false },
        };
        prepass.resyncAfterConstMaterializationRetainingGraph(&context, &module, failing.allocator(), &.{materialized}) catch {
            failures += 1;
            try std.testing.expectEqual(@intFromPtr(before.symbol_ids.ptr), @intFromPtr(module.semantic.?.symbol_ids.ptr));
            try std.testing.expectEqual(@intFromPtr(before.references.ptr), @intFromPtr(module.semantic.?.references.ptr));
            continue;
        };
    }
    try std.testing.expect(failures > 0);
}

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const module_mod = @import("../module.zig");
const Module = module_mod.Module;
const ModuleSemanticData = module_mod.ModuleSemanticData;
const Linker = @import("../linker.zig").Linker;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const ScopeKind = @import("../../semantic/scope.zig").ScopeKind;
const scope_owner_proof = @import("../../semantic/scope_owner_proof.zig");
const ast_walk = @import("../../parser/ast_walk.zig");
const constant_facts = @import("../constant_facts.zig");
const ConstValue = @import("../../semantic/symbol.zig").ConstValue;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const profile = @import("../../profile.zig");
const TreeShaker = @import("../tree_shaker.zig").TreeShaker;
const semantic_editor = @import("../../semantic/editor.zig");
const function_receipt = @import("../../semantic/function_retirement_receipt.zig");
const runtime_witness = @import("../../semantic/output_runtime_witness.zig");
const runtime_registration = @import("../../semantic/output_runtime_registration.zig");

pub const Scratch = constant_facts.Scratch;

fn getModule(self: *const TreeShaker, idx: u32) ?*const Module {
    return self.graph.getModule(ModuleIndex.fromUsize(idx));
}

fn moduleAtMut(self: *const TreeShaker, idx: u32) ?*Module {
    return self.graph.moduleAtMut(ModuleIndex.fromUsize(idx));
}

fn constValuesContainNumber(const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue)) bool {
    var it = const_values.valueIterator();
    while (it.next()) |cv| {
        if (cv.kind == .number) return true;
    }
    return false;
}

/// Constant propagation may replace only exact value-read nodes from the
/// semantic reference list. `symbol_ids` also marks import declaration nodes,
/// whose AST tag can be `identifier_reference`; using the ID slice alone would
/// rewrite an import specifier along with its reads.
fn materializableReferenceNodes(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    semantic: ModuleSemanticData,
) !std.DynamicBitSet {
    var nodes = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
    errdefer nodes.deinit();
    for (semantic.references) |reference| {
        if (!reference.flags.read or reference.flags.write or reference.flags.declare or
            reference.flags.type_context or reference.flags.value_as_type or reference.node_index.isNone())
        {
            continue;
        }
        const raw = @backingInt(reference.node_index);
        if (raw >= ast.nodes.items.len or raw >= semantic.symbol_ids.len) continue;
        if (ast.nodes.items[raw].tag != .identifier_reference) continue;
        const symbol_id = semantic.symbol_ids[raw] orelse continue;
        if (symbol_id != @backingInt(reference.symbol_id)) continue;
        nodes.set(raw);
    }
    return nodes;
}

const ConstMaterializeFilter = enum {
    all,
    numeric,
    numeric_export_chain,
};

/// Which phase owns a materialize call. The policy controls whether a safe
/// numeric leaf replacement can skip minify, and whether resync can use the
/// import/export-stable const-materialize path.
const ConstPassPolicy = enum {
    pre_pass,
    numeric_post_pass,

    fn skipMinifyIfSafe(self: ConstPassPolicy) bool {
        return self == .numeric_post_pass;
    }

    fn stableImportExportSyntax(self: ConstPassPolicy) bool {
        return self == .numeric_post_pass;
    }
};

const ConstMaterializeProfile = struct {
    policy: ConstPassPolicy,
    build_facts: ?profile.Category = null,
    build_facts_resolve: ?profile.Category = null,
    build_facts_lookup: ?profile.Category = null,
    candidate_gate: ?profile.Category = null,
    materialize: ?profile.Category = null,
    minify_resync: ?profile.Category = null,
    minify: ?profile.Category = null,
    resync: ?profile.Category = null,
    minify_skip: ?profile.Category = null,
    inner: constant_facts.MaterializeProfile = .{},
};

const MinifiedScopeOwnerSnapshot = struct {
    owner_node: u32,
    scope_id: u32,
    owner_tag: Node.Tag,
    scope_kind: ScopeKind,
};

/// Syntax minification may detach a lexical block that owns a semantic scope.
/// Snapshot the exact live owner pairs before minification so only scopes whose
/// owners were live and later removed by this pass can be considered for elision.
fn snapshotMinifiedScopeOwners(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    semantic: ModuleSemanticData,
) ?[]MinifiedScopeOwnerSnapshot {
    if (semantic.scope_owner_map.count() < semantic.scopes.len) return null;
    const reachable_nodes = ast_walk.collectReachableNodeIndices(allocator, ast) catch return null;
    defer allocator.free(reachable_nodes);
    var reachable = std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len) catch return null;
    defer reachable.deinit();
    for (reachable_nodes) |raw| {
        if (raw >= ast.nodes.items.len) return null;
        reachable.set(raw);
    }

    const owner_counts = allocator.alloc(u32, semantic.scopes.len) catch return null;
    defer allocator.free(owner_counts);
    @memset(owner_counts, 0);
    var snapshots: std.ArrayListUnmanaged(MinifiedScopeOwnerSnapshot) = .empty;
    defer snapshots.deinit(allocator);
    var owners = semantic.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner_node = entry.key_ptr.*;
        const scope_id = entry.value_ptr.*;
        if (owner_node >= ast.nodes.items.len or !reachable.isSet(owner_node) or
            scope_id >= semantic.scopes.len) return null;
        if (owner_counts[scope_id] >= 2) return null;
        owner_counts[scope_id] += 1;
        snapshots.append(allocator, .{
            .owner_node = owner_node,
            .scope_id = scope_id,
            .owner_tag = ast.nodes.items[owner_node].tag,
            .scope_kind = semantic.scopes[scope_id].kind,
        }) catch return null;
    }
    for (0..semantic.scopes.len) |scope_id| {
        if (owner_counts[scope_id] == 0) return null;
        if (semantic.scopes[scope_id].kind == .class_static_block) {
            if (owner_counts[scope_id] != 2 or !scope_owner_proof.exactClassStaticBlockScopeOwners(
                ast,
                semantic.scopes,
                &semantic.scope_owner_map,
                &reachable,
                @intCast(scope_id),
            )) return null;
        } else if (owner_counts[scope_id] != 1) {
            return null;
        }
    }
    return snapshots.toOwnedSlice(allocator) catch null;
}

fn prepassProfile() ConstMaterializeProfile {
    return .{
        .policy = .pre_pass,
        .build_facts = .shake_const_prepass_build_facts,
        .build_facts_resolve = .shake_const_prepass_build_facts_resolve,
        .build_facts_lookup = .shake_const_prepass_build_facts_lookup,
        .candidate_gate = .shake_const_prepass_candidate_gate,
        .materialize = .shake_const_prepass_materialize,
        .minify_resync = .shake_const_prepass_minify_resync,
        .inner = .{
            .forbidden = .shake_const_prepass_forbidden,
            .reachable = .shake_const_prepass_reachable,
            .replace = .shake_const_prepass_replace,
        },
    };
}

/// Reuses `TreeShaker.numeric_dfs_stack`; callers must not nest this traversal.
fn anyReachableNode(
    self: *TreeShaker,
    ast: *const Ast,
    root: NodeIndex,
    ctx: anytype,
    comptime visit_fn: fn (ctx: @TypeOf(ctx), ast: *const Ast, raw: u32, node: Node) bool,
) bool {
    if (root.isNone()) return false;
    self.numeric_dfs_stack.clearRetainingCapacity();
    self.numeric_dfs_stack.append(self.allocator, root) catch return false;
    while (self.numeric_dfs_stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const raw: u32 = @backingInt(idx);
        if (raw >= ast.nodes.items.len) continue;
        const node = ast.nodes.items[raw];
        if (visit_fn(ctx, ast, raw, node)) return true;
        var it = ast_walk.children(ast, node);
        while (it.next()) |child| {
            if (!child.isNone()) self.numeric_dfs_stack.append(self.allocator, child) catch return false;
        }
    }
    return false;
}

/// Visits top-level exported const initializers whose binding is not written.
fn anyExportedConstInit(
    self: *TreeShaker,
    ast: *const Ast,
    sem: ModuleSemanticData,
    ctx: anytype,
    comptime visit_fn: fn (self: *TreeShaker, ctx: @TypeOf(ctx), ast: *const Ast, init_idx: NodeIndex) bool,
) bool {
    for (ast.nodes.items) |node| {
        if (node.tag != .variable_declarator) continue;
        const extra = node.data.extra;
        if (extra + 2 >= ast.extra_data.items.len) continue;
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
        const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + 2]));
        if (name_idx.isNone() or init_idx.isNone()) continue;
        const name_raw: u32 = @backingInt(name_idx);
        if (name_raw >= sem.symbol_ids.len) continue;
        const sym_id = sem.symbol_ids[name_raw] orelse continue;
        if (sym_id >= sem.symbols.items.len) continue;
        const sym = sem.symbols.items[sym_id];
        if (!sym.isExported()) continue;
        if (sym.write_count != 0) continue;
        if (visit_fn(self, ctx, ast, init_idx)) return true;
    }
    return false;
}

const NumericConstRefCtx = struct {
    symbol_ids: []const ?u32,
    numeric_bitset: *const std.DynamicBitSet,
};

fn visitNumericConstRef(ctx: NumericConstRefCtx, _: *const Ast, raw: u32, node: Node) bool {
    if (node.tag != .identifier_reference or raw >= ctx.symbol_ids.len) return false;
    const sid = ctx.symbol_ids[raw] orelse return false;
    if (sid >= ctx.numeric_bitset.capacity()) return false;
    return ctx.numeric_bitset.isSet(sid);
}

fn nodeContainsNumericConstRef(
    self: *TreeShaker,
    ast: *const Ast,
    symbol_ids: []const ?u32,
    root: NodeIndex,
    numeric_bitset: *const std.DynamicBitSet,
) bool {
    return anyReachableNode(self, ast, root, NumericConstRefCtx{
        .symbol_ids = symbol_ids,
        .numeric_bitset = numeric_bitset,
    }, visitNumericConstRef);
}

fn visitChainExportInit(self: *TreeShaker, ctx: NumericConstRefCtx, ast: *const Ast, init_idx: NodeIndex) bool {
    return nodeContainsNumericConstRef(self, ast, ctx.symbol_ids, init_idx, ctx.numeric_bitset);
}

/// Detects exported numeric-const chains without a HashMap lookup at every
/// identifier by building a per-module numeric-symbol bitset once.
fn moduleHasNumericExportConstChain(
    self: *TreeShaker,
    ast: *const Ast,
    sem: ModuleSemanticData,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
) bool {
    if (!constValuesContainNumber(const_values)) return false;
    var numeric_bitset = std.DynamicBitSet.initEmpty(self.allocator, sem.symbols.items.len) catch return false;
    defer numeric_bitset.deinit();
    var it = const_values.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind != .number) continue;
        const sid = entry.key_ptr.*;
        if (sid >= sem.symbols.items.len) continue;
        numeric_bitset.set(sid);
    }
    return anyExportedConstInit(self, ast, sem, NumericConstRefCtx{
        .symbol_ids = sem.symbol_ids,
        .numeric_bitset = &numeric_bitset,
    }, visitChainExportInit);
}

/// Folds numeric literal expressions on exported const seeds before propagation.
fn foldNumericExportSeeds(_: *TreeShaker, m: *Module, ast: *Ast) !bool {
    const minify_mod = @import("../../transformer/minify.zig");
    const sem = if (m.semantic) |*sem| sem else return false;
    const arena_alloc = if (m.parse_arena) |arena| arena.allocator() else return false;
    var has_exported_number = false;

    for (ast.nodes.items) |node| {
        if (node.tag != .variable_declarator) continue;
        const extra = node.data.extra;
        if (extra + 2 >= ast.extra_data.items.len) continue;
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra]));
        const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra + 2]));
        if (name_idx.isNone() or init_idx.isNone()) continue;
        const name_raw: u32 = @backingInt(name_idx);
        if (name_raw >= sem.symbol_ids.len) continue;
        const sym_id = sem.symbol_ids[name_raw] orelse continue;
        if (sym_id >= sem.symbols.items.len) continue;
        const sym = sem.symbols.items[sym_id];
        if (!sym.isExported()) continue;
        if (sym.write_count != 0) continue;

        if (sym.const_kind == .number and sem.numericConstText(@intCast(sym_id)).len > 0) {
            has_exported_number = true;
            continue;
        }

        const folded_span = minify_mod.foldNumericLiteralExpression(ast, init_idx) orelse continue;
        const number_text = try arena_alloc.dupe(u8, ast.getText(folded_span));
        try sem.numeric_const_texts.put(arena_alloc, @intCast(sym_id), number_text);
        sem.symbols.items[sym_id].const_kind = .number;
        has_exported_number = true;
    }

    return has_exported_number;
}

fn moduleHasExportedNumberConstValue(sem: ModuleSemanticData) bool {
    for (sem.symbols.items) |sym| {
        if (!sym.isExported()) continue;
        if (sym.write_count != 0) continue;
        if (sym.const_kind == .number) return true;
    }
    return false;
}

pub fn anyModuleHasExportedNumberConst(self: *TreeShaker, mod_count: usize) bool {
    for (0..mod_count) |i| {
        const m = getModule(self, @intCast(i)) orelse continue;
        const sem = m.semantic orelse continue;
        if (moduleHasExportedNumberConstValue(sem)) return true;
    }
    return false;
}

/// Numeric chain folding runs after reachability for preserve-modules and
/// non-minify builds; minify-syntax already materializes the full pre-pass.
pub fn shouldRunNumericPostPass(self: *const TreeShaker) bool {
    return self.graph.preserve_modules or !self.graph.transform_options_base.minify_syntax;
}

/// Keep the existing semantic graph when numeric materialization skipped the
/// syntax minifier. The edit removes only exact, currently reachable reads and
/// preserves symbol indices, so prepass ref deltas remain aligned for emitter
/// minify to apply to the updated base reference counts.
fn markConstMaterializedRetainingGraph(
    self: *TreeShaker,
    m: *Module,
    materialized_nodes: []const NodeIndex,
) bool {
    std.debug.assert(m.parse_arena != null);
    self.graph.resyncModuleMetadataAfterConstMaterializationRetainingGraph(
        m,
        m.parse_arena.?.allocator(),
        materialized_nodes,
    ) catch return false;
    m.namespace_access_index = null;
    self.ast_mutated_after_link = true;
    return true;
}

fn markConstMaterializedRetainingMinifiedGraph(
    self: *TreeShaker,
    m: *Module,
    materialized_nodes: []const NodeIndex,
    scope_owner_snapshot: []const MinifiedScopeOwnerSnapshot,
    refresh_module_metadata: bool,
) bool {
    std.debug.assert(m.parse_arena != null);
    const retained = self.graph.resyncModuleMetadataAfterConstMaterializationRetainingMinifiedGraph(
        m,
        m.parse_arena.?.allocator(),
        materialized_nodes,
        scope_owner_snapshot,
        refresh_module_metadata,
    ) catch false;
    if (!retained) return false;
    m.namespace_access_index = null;
    self.ast_mutated_after_link = true;
    return true;
}

/// Folding an imported numeric seed can create a new exported literal.
/// Retaining the graph also retains its old constant facts, so publish the
/// new value through the surviving declaration's exact identity.
fn refreshFoldedNumericExportFacts(self: *TreeShaker, m: *Module, ast: *Ast) !void {
    const allocator = if (m.parse_arena) |arena| arena.allocator() else return;
    return refreshFoldedNumericExportFactsWithAllocator(self, m, ast, allocator);
}

fn refreshFoldedNumericExportFactsWithAllocator(self: *TreeShaker, m: *Module, ast: *Ast, allocator: std.mem.Allocator) !void {
    const sem = if (m.semantic) |*value| value else return;
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    if (ast.nodes.items.len == 0) return;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@intCast(ast.nodes.items.len - 1)));
    const reachable = try ast_walk.collectReachableNodeIndicesFrom(scratch.allocator(), ast, root);
    for (reachable) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .variable_declarator) continue;
        const extra = node.data.extra;
        if (extra + 2 >= ast.extra_data.items.len) continue;
        const binding = ast.extra_data.items[extra];
        const initializer = ast.extra_data.items[extra + 2];
        if (binding >= sem.symbol_ids.len or initializer >= ast.nodes.items.len) continue;
        const id = sem.symbol_ids[binding] orelse continue;
        if (id >= sem.symbols.items.len) continue;
        const symbol = &sem.symbols.items[id];
        if (!symbol.isExported() or (symbol.kind != .variable_const and symbol.kind != .variable_let) or symbol.write_count != 0) continue;
        const literal = ast.nodes.items[initializer];
        if (literal.tag != .numeric_literal) continue;
        const text = ast.getText(literal.span);
        if (text.len == 0) continue;
        if (symbol.const_kind == .number and std.mem.eql(u8, sem.numericConstText(id), text)) continue;
        const owned_text = try allocator.dupe(u8, text);
        try sem.numeric_const_texts.put(allocator, id, owned_text);
        symbol.const_kind = .number;
    }
}

fn minifyAndResyncModule(
    self: *TreeShaker,
    m: *Module,
    sem: ModuleSemanticData,
    ast: *Ast,
    const_profile: ConstMaterializeProfile,
    materialized: constant_facts.MaterializeResult,
    materialized_nodes: []const NodeIndex,
    skip_minify: bool,
) !bool {
    var scope = profile.beginMaybe(const_profile.minify_resync);
    defer scope.end();

    var scope_owner_snapshot: ?[]MinifiedScopeOwnerSnapshot = null;
    defer if (scope_owner_snapshot) |snapshot| self.allocator.free(snapshot);

    if (skip_minify) {
        var skip_scope = profile.beginMaybe(const_profile.minify_skip);
        defer skip_scope.end();
    } else {
        var minify_scope = profile.beginMaybe(const_profile.minify);
        defer minify_scope.end();

        const minify_mod = @import("../../transformer/minify.zig");
        const root = ast.transformed_root orelse NodeIndex.none;
        const ctx = minify_mod.MinifyCtx.fromSemantic(&m.semantic.?, sem.symbol_ids, self.graph.transform_options_base.minify_syntax);
        if (m.semantic) |semantic| {
            scope_owner_snapshot = snapshotMinifiedScopeOwners(self.allocator, ast, semantic);
        }
        minify_mod.minify(ast, ctx, self.allocator, root);
    }

    {
        var resync_scope = profile.beginMaybe(const_profile.resync);
        defer resync_scope.end();

        const retained = if (m.semantic != null and materialized.tracked_nodes_complete) blk: {
            if (skip_minify) break :blk markConstMaterializedRetainingGraph(self, m, materialized_nodes);
            const snapshot = scope_owner_snapshot orelse break :blk false;
            break :blk markConstMaterializedRetainingMinifiedGraph(
                self,
                m,
                materialized_nodes,
                snapshot,
                !const_profile.policy.stableImportExportSyntax(),
            );
        } else false;
        if (!retained) return false;
    }
    try refreshFoldedNumericExportFacts(self, m, ast);
    return true;
}

fn addConstRoot(roots: *std.AutoHashMapUnmanaged(u32, void), a: std.mem.Allocator, symbol_count: usize, id: @import("../../semantic/symbol.zig").SymbolId) !void {
    if (id.isNone()) return;
    const raw = @backingInt(id);
    if (raw >= symbol_count) return error.InvalidConstOutputRoot;
    try roots.put(a, raw, {});
}

fn addConstRuntimeRoots(roots: *std.AutoHashMapUnmanaged(u32, void), a: std.mem.Allocator, symbol_count: usize, value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime T == @import("../../semantic/symbol.zig").SymbolId) {
        try addConstRoot(roots, a, symbol_count, value);
    } else switch (@typeInfo(T)) {
        .optional => if (value) |present| try addConstRuntimeRoots(roots, a, symbol_count, present),
        .@"struct" => |info| inline for (info.field_names) |name| try addConstRuntimeRoots(roots, a, symbol_count, @field(value, name)),
        else => @compileError("unclassified runtime identity snapshot field"),
    }
}

fn constModuleOutputRoots(a: std.mem.Allocator, m: *const Module) ![]const u32 {
    const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
    const sem = m.semantic orelse return error.MissingSemantic;
    var roots: std.AutoHashMapUnmanaged(u32, void) = .empty;
    // Direct Module SID fields are typed. Newly added typed fields participate
    // automatically; no spelling, span, or numerically guessed slot is used.
    const info = @typeInfo(Module).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime T == SymbolId or T == ?SymbolId)
            try addConstRuntimeRoots(&roots, a, sem.symbols.items.len, @field(m.*, name));
    }
    inline for (.{ "cjs_runtime_internal_symbols", "esm_runtime_internal_symbols", "esm_interop_runtime_helper_symbols", "esm_interop_runtime_internal_symbols", "hmr_runtime_internal_symbols" }) |name|
        try addConstRuntimeRoots(&roots, a, sem.symbols.items.len, @field(m.*, name));
    if (sem.runtime_identities) |snapshot| try addConstRuntimeRoots(&roots, a, sem.symbols.items.len, snapshot.*);
    for (m.export_bindings) |binding| switch (binding.symbol) {
        .semantic => |known| if (known.module == m.index) try addConstRoot(&roots, a, sem.symbols.items.len, known.symbol),
        .alias => {}, // AliasId is a different identity space.
    };
    for (m.import_bindings) |binding| {
        inline for (.{ binding.local_symbol, binding.symbol }) |reference| switch (reference) {
            .semantic => |known| if (known.module == m.index) try addConstRoot(&roots, a, sem.symbols.items.len, known.symbol),
            .alias => {},
        };
    }
    for (sem.strict_output_context.functions) |role| try addConstRoot(&roots, a, sem.symbols.items.len, role.symbol);
    if (m.tla_promise_reference) |known| {
        if (!m.matchesTlaPromiseReference(known.binding_node_index)) return error.InvalidConstOutputRoot;
        try addConstRoot(&roots, a, sem.symbols.items.len, known.symbol_id);
    }
    if (m.transform_cache) |cache| {
        inline for (.{ cache.worklet_factory_local_bindings, cache.post_graph_output_bindings, cache.runtime_helper_import_output_bindings }) |bindings| {
            for (bindings) |binding| {
                if (binding.node_index >= sem.symbol_ids.len) return error.InvalidConstOutputRoot;
                const raw = sem.symbol_ids[binding.node_index] orelse return error.InvalidConstOutputRoot;
                try addConstRoot(&roots, a, sem.symbols.items.len, @fromBackingInt(raw));
            }
        }
    }
    var result: std.ArrayList(u32) = .empty;
    var ids = roots.keyIterator();
    while (ids.next()) |raw| try result.append(a, raw.*);
    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(a);
}

fn captureConstSourceExternals(a: std.mem.Allocator, source: *const Module) ![]const u32 {
    const ast = &source.ast.?;
    const sem = source.semantic.?;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    var result: std.ArrayList(u32) = .empty;
    for (try @import("../../semantic/reference_walk.zig").collectIdentifierReferences(a, ast, root)) |node| {
        const raw = @backingInt(node);
        if (raw >= sem.symbol_ids.len or sem.symbol_ids[raw] != null) continue;
        const actual = ast.getNode(node);
        const name = ast.identifierNameText(actual);
        var unresolved = sem.unresolved_references.contains(name);
        // Only source identifier syntax is decoded; string-table name values
        // retain their producer role and are never decoded a second time.
        if (!unresolved and actual.data.string_ref.start & Ast.STRING_TABLE_BIT == 0 and std.mem.indexOfScalar(u8, name, '\\') != null) {
            const decoded = try @import("../../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, name);
            unresolved = sem.unresolved_references.contains(decoded);
        }
        if (unresolved) try result.append(a, raw);
    }
    return result.toOwnedSlice(a);
}

fn prepareJournalConstMinification(
    self: *TreeShaker,
    prepared: *PreparedConstModule,
    reads: []const function_receipt.MaterializedRead,
    runtime_source: *const runtime_witness.Source,
    const_profile: ConstMaterializeProfile,
) !bool {
    var total_scope = profile.beginMaybe(const_profile.minify_resync);
    defer total_scope.end();
    const a = prepared.persistent;
    const m = prepared.candidate;
    const ast = &m.ast.?;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    var removal_nodes: std.ArrayList(NodeIndex) = .empty;
    var materialization_changes: std.ArrayList(function_receipt.ReferenceChange) = .empty;
    for (reads) |read| {
        try removal_nodes.append(a, read.node);
        try materialization_changes.append(a, .{ .before = read.before_reference, .after = null });
    }
    var materializer_editor = try m.semantic.?.beginEdit(a, ast);
    try materializer_editor.removeReferences(removal_nodes.items);
    m.semantic.?.applyEdit(try materializer_editor.finish());
    const sem = &m.semantic.?;
    const minify_mod = @import("../../transformer/minify.zig");
    const Journal = @import("../../transformer/minify/semantic_journal.zig").SemanticJournal;
    var journal = try Journal.init(self.allocator, sem.references, .{
        .domain = ast,
        .root = root,
        .symbol_ids = sem.symbol_ids,
        .owners = &sem.scope_owner_map,
        .expressions = &sem.node_scope_provenance,
        .class_self = &sem.class_self_symbol_map,
        .symbols = sem.symbols.items,
        .scopes = sem.scopes,
        .scope_maps = sem.scope_maps,
    });
    defer journal.deinit();
    var ctx = minify_mod.MinifyCtx.fromSemantic(sem, sem.symbol_ids, self.graph.transform_options_base.minify_syntax);
    ctx.semantic_journal = &journal;
    {
        var minify_scope = profile.beginMaybe(const_profile.minify);
        defer minify_scope.end();
        minify_mod.minify(ast, ctx, self.allocator, root);
    }
    var resync_scope = profile.beginMaybe(const_profile.resync);
    defer resync_scope.end();
    var graph_scope = profile.begin(.graph_resync);
    defer graph_scope.end();
    var graph_const_scope = profile.begin(.graph_resync_const);
    defer graph_const_scope.end();
    var editor = try sem.beginEdit(a, ast);
    var origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer origins.deinit(self.allocator);
    const phase = try journal.applyReferenceAndOwnerEdits(&editor, root, &origins, &sem.class_self_symbol_map);
    defer journal.freeApplicationReceipt(phase);
    var receipt = phase;
    const changes = try a.alloc(function_receipt.ReferenceChange, materialization_changes.items.len + phase.reference_changes.len);
    @memcpy(changes[0..materialization_changes.items.len], materialization_changes.items);
    @memcpy(changes[materialization_changes.items.len..], phase.reference_changes);
    receipt.reference_changes = changes;
    receipt.materialized_reads = reads;
    if (prepared.function_sources) |source| {
        const selected = try selectRetiredConstFunctions(a, source, ast, receipt);
        if (selected.len != 0 and !try editor.retireSelectedSourceOwnedFunctions(source, selected, receipt)) return false;
    }
    try journal.retireDeadDeclarationAnchors(&editor, root);
    sem.applyEdit(try editor.finish());
    if (m.transform_cache) |*cache| {
        if (!try journal.accountsForBaselineDeltas(phase, cache.ref_deltas)) return false;
        if (cache.ref_deltas.len != 0) {
            const accounted = try a.alloc(u32, sem.symbols.items.len);
            @memset(accounted, 0);
            cache.ref_deltas = accounted;
        }
    }
    try prepared.prepareCache(receipt);
    try @import("../graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(self.graph, m, a);
    try @import("../graph/requested_exports.zig").populateExportIndexByName(m, self.graph.allocator);
    for (m.export_bindings) |binding| _ = try m.ordinaryQuotedExportLiteral(binding);
    m.prebuilt_stmt_info = try @import("../stmt_info.zig").buildFromSemantic(a, ast, sem.symbols.items, sem.scopes, sem.symbol_ids, sem.references, &sem.unresolved_references, false, m.memberAugmentGate(self.graph.transform_options_base.minify_syntax));
    var unresolved: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var explicit: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const source_unresolved = try captureConstSourceExternals(a, prepared.source);
    for (try remapConstReferenceNodes(a, source_unresolved, &prepared.source.ast.?, ast, receipt)) |raw| try unresolved.put(a, raw, {});
    const helpers = if (m.transform_cache) |cache| cache.helper_ref_nodes else &.{};
    if (m.transform_cache) |cache| for (cache.explicit_global_ref_nodes) |raw| try explicit.put(a, raw, {});
    const coverage = @import("../../transformer/symbol_coverage.zig");
    var helper_roots: std.StringHashMapUnmanaged(@import("../../semantic/symbol.zig").SymbolId) = .empty;
    var helpers_by_name = sem.helper_scope_map.iterator();
    while (helpers_by_name.next()) |entry| {
        if (entry.value_ptr.* >= sem.symbols.items.len) return error.InvalidConstOutputRoot;
        try helper_roots.put(a, entry.key_ptr.*, @fromBackingInt(@as(u32, @intCast(entry.value_ptr.*))));
    }
    const output_roots = try constModuleOutputRoots(a, m);
    const runtime_proof = @import("../../semantic/output_runtime_coverage.zig").forTarget(.{ .source = runtime_source, .module = m }) orelse return false;
    var normal_form = try coverage.checkOutputNormalFormQuiet(self.allocator, ast, root, @intCast(prepared.source.ast.?.nodes.items.len), sem.symbol_ids, sem.symbols.items, sem.scopes, sem.scope_maps, &sem.scope_owner_map, sem.references, helpers, &sem.helper_scope_map, &unresolved, &explicit, &origins, .{
        .namespace_member_owners = &sem.namespace_member_owners,
        .namespace_declaration_owners = &sem.namespace_declaration_owners,
        .pre_transform_scope_count = prepared.source.semantic.?.scopes.len,
    }, &sem.source_owned_retirements, .{
        .symbol_ids = output_roots,
        .node_scope_provenance = &sem.node_scope_provenance,
        .scope_history = &sem.scope_history,
        .runtime_output_proof = runtime_proof,
        .runtime_helper_symbols = &helper_roots,
        .class_self_symbols = &sem.class_self_symbol_map,
        .namespace_member_owners = &sem.namespace_member_owners,
        .namespace_declaration_owners = &sem.namespace_declaration_owners,
    });
    defer normal_form.deinit(self.allocator);
    if (!normal_form.hasCompleteOutputIdentityBeforeNames()) return false;
    try refreshFoldedNumericExportFactsWithAllocator(self, m, ast, a);
    m.namespace_access_index = null;
    self.ast_mutated_after_link = true;
    return true;
}

fn shouldMaterializeConstFacts(
    self: *TreeShaker,
    ast: *const Ast,
    sem: ModuleSemanticData,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
    filter: ConstMaterializeFilter,
) bool {
    return switch (filter) {
        .all => const_values.count() > 0,
        .numeric => constValuesContainNumber(const_values),
        .numeric_export_chain => moduleHasNumericExportConstChain(self, ast, sem, const_values),
    };
}

/// Persistent candidate storage belongs to the existing parse arena. Aborting
/// discards publication, never frees backing still borrowed by the source AST.
const PreparedConstModule = struct {
    source: *Module,
    candidate: *Module,
    heap: std.mem.Allocator,
    persistent: std.mem.Allocator,
    published: bool = false,
    function_sources: ?*const semantic_editor.SourceOwnedFunction = null,

    fn init(source: *Module, heap: std.mem.Allocator, a: std.mem.Allocator) !PreparedConstModule {
        if (source.parse_arena == null) return error.MissingParseArena;
        const candidate = try a.create(Module);
        candidate.* = source.*;
        candidate.alias_table = null;
        candidate.export_index_by_name = null;
        var prepared: PreparedConstModule = .{ .source = source, .candidate = candidate, .heap = heap, .persistent = a };
        errdefer prepared.discard();
        const old_ast = if (source.ast) |*ast| ast else return error.MissingAst;
        // Carry every scalar/header field, including TLA/type-only metadata;
        // cloneForTransformer supplies detached mutable node/string backings.
        const backing = try old_ast.cloneForTransformer(a);
        candidate.ast = old_ast.*;
        const ast = &candidate.ast.?;
        ast.allocator = a;
        ast.nodes = backing.nodes;
        ast.extra_data = backing.extra_data;
        ast.string_table = backing.string_table;
        ast.string_interns = backing.string_interns;
        ast.preserve_lexical_declaration_indices = backing.preserve_lexical_declaration_indices;
        ast.type_only_binding_names = try old_ast.type_only_binding_names.clone(a);
        const original = source.semantic orelse return error.MissingSemantic;
        var editor = try original.beginEdit(a, ast);
        candidate.semantic.?.applyEdit(try editor.finish());
        candidate.semantic.?.class_self_symbol_map = try original.class_self_symbol_map.clone(a);
        candidate.semantic.?.numeric_const_texts = try original.numeric_const_texts.clone(a);
        candidate.import_bindings = try a.dupe(module_mod.ImportBinding, source.import_bindings);
        candidate.export_bindings = try a.dupe(module_mod.ExportBinding, source.export_bindings);
        for (candidate.export_bindings) |*binding| {
            if (binding.public_key_origin) |*origin| {
                if (origin.ast != old_ast) return error.InvalidQuotedExportOrigin;
                origin.ast = ast;
            }
        }
        if (candidate.transform_cache) |*cache| cache.symbol_ids = candidate.semantic.?.symbol_ids;
        // Capture immutable actual function inputs before the first literal
        // replacement. Nested/live functions are captured, then selected by
        // their exact source owners after the producer has finished.
        var functions: std.ArrayList(semantic_editor.KnownUnreachableFunction) = .empty;
        const reachable = try ast_walk.collectReachableNodeIndices(a, ast);
        for (reachable) |raw| {
            const node = ast.nodes.items[raw];
            if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .arrow_function_expression) continue;
            const scope = candidate.semantic.?.scope_owner_map.get(raw) orelse return error.InvalidFunctionOwner;
            const slot: u32 = if (node.tag == .arrow_function_expression) 0 else ast_mod.FunctionExtra.params;
            if (!ast.hasExtra(node.data.extra, slot + 1)) return error.InvalidFunctionOwner;
            const params = ast.readExtraNode(node.data.extra, slot);
            const body = ast.readExtraNode(node.data.extra, slot + 1);
            try functions.append(a, .{
                .owner = @fromBackingInt(raw),
                .scope = @fromBackingInt(scope),
                .params = params,
                .body = body,
                .body_scope = if (candidate.semantic.?.scope_owner_map.get(@backingInt(body))) |known| @fromBackingInt(known) else .none,
            });
        }
        if (functions.items.len != 0) {
            var capture_editor = try candidate.semantic.?.beginEdit(a, ast);
            prepared.function_sources = try capture_editor.captureFunctionRetirementSources(functions.items);
        }
        return prepared;
    }

    fn prepareCache(self: *PreparedConstModule, receipt: function_receipt.ApplicationReceipt) !void {
        const source_cache = self.source.transform_cache orelse return;
        const cache = if (self.candidate.transform_cache) |*value| value else return error.MissingConstTransformCache;
        const a = self.persistent;
        const source_ast = &self.source.ast.?;
        const ast = &self.candidate.ast.?;
        const source_sem = self.source.semantic.?;
        const sem = self.candidate.semantic.?;
        cache.helper_ref_nodes = try remapConstReferenceNodes(a, source_cache.helper_ref_nodes, source_ast, ast, receipt);
        cache.explicit_global_ref_nodes = try remapConstReferenceNodes(a, source_cache.explicit_global_ref_nodes, source_ast, ast, receipt);
        cache.opaque_define_scope_owner_nodes = try remapConstOwnerNodes(a, source_cache.opaque_define_scope_owner_nodes, source_sem, sem, ast, receipt);
        cache.worklet_factory_local_bindings = try remapConstOutputBindings(module_mod.WorkletFactoryLocalBinding, a, source_cache.worklet_factory_local_bindings, source_sem.symbol_ids, sem.symbol_ids, ast, receipt);
        cache.post_graph_output_bindings = try remapConstOutputBindings(module_mod.PostGraphOutputBinding, a, source_cache.post_graph_output_bindings, source_sem.symbol_ids, sem.symbol_ids, ast, receipt);
        cache.runtime_helper_import_output_bindings = try remapConstOutputBindings(module_mod.RuntimeHelperImportOutputBinding, a, source_cache.runtime_helper_import_output_bindings, source_sem.symbol_ids, sem.symbol_ids, ast, receipt);
        cache.preserved_class_name_nodes = try remapConstBindingNodes(a, source_cache.preserved_class_name_nodes, source_sem.symbol_ids, sem.symbol_ids, ast, receipt);
        var temps: std.ArrayList(u32) = .empty;
        var source_temps = source_cache.destructuring_temp_bindings.keyIterator();
        while (source_temps.next()) |raw| try temps.append(a, raw.*);
        cache.destructuring_temp_bindings = .empty;
        for (try remapConstBindingNodes(a, temps.items, source_sem.symbol_ids, sem.symbol_ids, ast, receipt)) |raw|
            try cache.destructuring_temp_bindings.put(a, raw, {});
        cache.symbol_ids = sem.symbol_ids;
    }

    fn discard(self: *PreparedConstModule) void {
        if (self.published) return;
        if (self.candidate.alias_table) |*table| table.deinit();
        if (self.candidate.export_index_by_name) |*map| map.deinit(self.heap);
        self.candidate.alias_table = null;
        self.candidate.export_index_by_name = null;
    }

    fn publish(self: *PreparedConstModule) void {
        // Origin domain rebasing is permitted only for the exact prepared
        // carrier. Validation and every allocation have already completed.
        for (self.candidate.export_bindings) |*binding| {
            if (binding.public_key_origin) |*origin| {
                std.debug.assert(origin.ast == &self.candidate.ast.?);
                origin.ast = &self.source.ast.?;
            }
        }
        if (self.source.alias_table) |*table| table.deinit();
        if (self.source.export_index_by_name) |*map| map.deinit(self.heap);
        self.source.* = self.candidate.*;
        self.published = true;
    }
};

/// Carry reference-role cache markers only through actual ordered copies.
/// Dead markers are omitted; new markers are never selected by spelling.
fn remapConstReferenceNodes(
    a: std.mem.Allocator,
    before: []const u32,
    before_ast: *const Ast,
    ast: *const Ast,
    receipt: function_receipt.ApplicationReceipt,
) ![]const u32 {
    if (receipt.domain != ast) return error.ForeignConstFunctionDomain;
    if (before.len == 0) return &.{};
    const before_root = before_ast.transformed_root orelse if (before_ast.nodes.items.len == 0) NodeIndex.none else @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(before_ast.nodes.items.len - 1))));
    var before_live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (try @import("../../semantic/reference_walk.zig").collectIdentifierReferences(a, before_ast, before_root)) |node|
        try before_live.put(a, @backingInt(node), {});
    var marked: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (before) |raw| {
        if (raw >= before_ast.nodes.items.len or !before_live.contains(raw)) return error.InvalidConstCacheMarker;
        const entry = try marked.getOrPut(a, raw);
        if (entry.found_existing) return error.InvalidConstCacheMarker;
    }
    for (receipt.copies) |copy| {
        const from = @backingInt(copy.source);
        const to = @backingInt(copy.target);
        const carries = marked.contains(from);
        _ = marked.remove(to);
        if (carries) try marked.put(a, to, {});
    }
    const root = ast.transformed_root orelse if (ast.nodes.items.len == 0) NodeIndex.none else @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (try @import("../../semantic/reference_walk.zig").collectIdentifierReferences(a, ast, root)) |node|
        try live.put(a, @backingInt(node), {});
    var result: std.ArrayList(u32) = .empty;
    var markers = marked.keyIterator();
    while (markers.next()) |raw| {
        if (!live.contains(raw.*)) continue;
        try result.append(a, raw.*);
    }
    // Both helper consumers use sorted node lists (including binary search).
    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(a);
}

fn remapConstOutputBindings(
    comptime T: type,
    a: std.mem.Allocator,
    before: []const T,
    source_ids: []const ?u32,
    candidate_ids: []const ?u32,
    ast: *const Ast,
    receipt: function_receipt.ApplicationReceipt,
) ![]const T {
    if (receipt.domain != ast) return error.ForeignConstFunctionDomain;
    if (before.len == 0) return &.{};
    const Entry = struct { binding: T, symbol: u32 };
    var bindings: std.AutoHashMapUnmanaged(u32, Entry) = .empty;
    for (before) |binding| {
        const raw = binding.node_index;
        if (raw >= source_ids.len) return error.InvalidConstCacheMarker;
        const symbol = source_ids[raw] orelse return error.InvalidConstCacheMarker;
        const entry = try bindings.getOrPut(a, raw);
        if (entry.found_existing) return error.InvalidConstCacheMarker;
        entry.value_ptr.* = .{ .binding = binding, .symbol = symbol };
    }
    for (receipt.copies) |copy| {
        const carried = bindings.get(@backingInt(copy.source));
        const target = @backingInt(copy.target);
        _ = bindings.remove(target);
        if (carried) |known| {
            var moved = known;
            moved.binding.node_index = target;
            try bindings.put(a, target, moved);
        }
    }
    var live = try std.DynamicBitSet.initEmpty(a, ast.nodes.items.len);
    for (try ast_walk.collectReachableNodeIndices(a, ast)) |raw| live.set(raw);
    var result: std.ArrayList(T) = .empty;
    var entries = bindings.iterator();
    while (entries.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= live.capacity()) return error.InvalidConstCacheMarker;
        if (!live.isSet(raw)) continue;
        if (raw >= candidate_ids.len or candidate_ids[raw] != entry.value_ptr.symbol or ast.nodes.items[raw].tag != .binding_identifier)
            return error.InvalidConstCacheMarker;
        try result.append(a, entry.value_ptr.binding);
    }
    return result.toOwnedSlice(a);
}

fn remapConstBindingNodes(a: std.mem.Allocator, before: []const u32, source_ids: []const ?u32, candidate_ids: []const ?u32, ast: *const Ast, receipt: function_receipt.ApplicationReceipt) ![]const u32 {
    if (before.len == 0) return &.{};
    const Binding = struct { node_index: u32 };
    const input = try a.alloc(Binding, before.len);
    for (before, input) |raw, *item| item.* = .{ .node_index = raw };
    const moved = try remapConstOutputBindings(Binding, a, input, source_ids, candidate_ids, ast, receipt);
    const output = try a.alloc(u32, moved.len);
    for (moved, output) |item, *raw| raw.* = item.node_index;
    std.mem.sort(u32, output, {}, std.sort.asc(u32));
    return output;
}

fn remapConstOwnerNodes(a: std.mem.Allocator, before: []const u32, source: ModuleSemanticData, candidate: ModuleSemanticData, ast: *const Ast, receipt: function_receipt.ApplicationReceipt) ![]const u32 {
    if (receipt.domain != ast) return error.ForeignConstFunctionDomain;
    if (before.len == 0) return &.{};
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (before) |raw| {
        const scope = source.scope_owner_map.get(raw) orelse return error.InvalidConstCacheMarker;
        const entry = try owners.getOrPut(a, raw);
        if (entry.found_existing) return error.InvalidConstCacheMarker;
        entry.value_ptr.* = scope;
    }
    for (receipt.owner_changes) |change| {
        const scope = owners.get(@backingInt(change.source_owner)) orelse continue;
        if (scope != @backingInt(change.scope)) return error.InvalidConstCacheMarker;
        _ = owners.remove(@backingInt(change.source_owner));
        if (change.target_owner) |target| try owners.put(a, @backingInt(target), scope);
    }
    var result: std.ArrayList(u32) = .empty;
    var entries = owners.iterator();
    while (entries.next()) |entry| {
        if (candidate.scope_owner_map.get(entry.key_ptr.*) != entry.value_ptr.*) return error.InvalidConstCacheMarker;
        try result.append(a, entry.key_ptr.*);
    }
    std.mem.sort(u32, result.items, {}, std.sort.asc(u32));
    return result.toOwnedSlice(a);
}

fn selectRetiredConstFunctions(
    a: std.mem.Allocator,
    plan: *const semantic_editor.SourceOwnedFunction,
    ast: *const Ast,
    receipt: function_receipt.ApplicationReceipt,
) ![]const NodeIndex {
    if (plan.domain != ast or receipt.domain != ast) return error.ForeignConstFunctionDomain;
    var live = try std.DynamicBitSet.initEmpty(a, ast.nodes.items.len);
    for (try ast_walk.collectReachableNodeIndices(a, ast)) |raw| live.set(raw);
    var selected: std.ArrayList(NodeIndex) = .empty;
    var covered = try std.DynamicBitSet.initEmpty(a, plan.source.nodes.items.len);
    // init captured this table in structural preorder. Thus a selected outer
    // source closure is encountered before each nested source function.
    for (plan.functions) |known| {
        const raw = @backingInt(known.owner);
        if (raw >= live.capacity() or raw >= covered.capacity()) return error.InvalidFunctionOwner;
        if (live.isSet(raw) or covered.isSet(raw)) continue;
        var transferred = false;
        for (receipt.owner_changes) |change| {
            if (change.source_owner != known.owner) continue;
            if (change.scope != known.scope or transferred) return error.InvalidFunctionOwner;
            switch (change.effect) {
                .move => if (change.target_owner == null) return error.InvalidFunctionOwner,
                .empty_arrow_elide => if (change.target_owner != null) return error.InvalidFunctionOwner,
            }
            transferred = true;
        }
        if (transferred) continue;
        try selected.append(a, known.owner);
        for (try ast_walk.collectReachableNodeIndicesFrom(a, plan.source, known.owner)) |member| {
            if (member >= covered.capacity()) return error.InvalidFunctionOwner;
            covered.set(member);
        }
    }
    return selected.toOwnedSlice(a);
}

/// The original Module is the immutable source witness for the exact clone.
/// Selection comes only from the materializer's actual output-node ledger.
fn captureMaterializedReads(
    a: std.mem.Allocator,
    original: *const Module,
    candidate: *const Module,
    nodes: []const NodeIndex,
    values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
) ![]const function_receipt.MaterializedRead {
    const before_ast = if (original.ast) |*ast| ast else return error.MissingAst;
    const after_ast = if (candidate.ast) |*ast| ast else return error.MissingAst;
    const before_sem = original.semantic orelse return error.MissingSemantic;
    var selected: std.AutoHashMapUnmanaged(u32, bool) = .empty;
    for (nodes) |node| {
        if (node.isNone() or @backingInt(node) >= before_ast.nodes.items.len or
            @backingInt(node) >= after_ast.nodes.items.len) return error.InvalidMaterializedNode;
        const slot = try selected.getOrPut(a, @backingInt(node));
        if (slot.found_existing) return error.InvalidMaterializedNode;
        slot.value_ptr.* = false;
    }
    var captured: std.ArrayList(function_receipt.MaterializedRead) = .empty;
    for (before_sem.references) |reference| {
        if (reference.node_index.isNone()) continue;
        const matched = selected.getPtr(@backingInt(reference.node_index)) orelse continue;
        if (matched.*) return error.InvalidMaterializedReference;
        matched.* = true;
        if (reference.flags.declare or !reference.flags.read or reference.flags.write or
            reference.flags.type_context or reference.flags.value_as_type) return error.InvalidMaterializedReference;
        const raw = @backingInt(reference.node_index);
        if (raw >= before_sem.symbol_ids.len) return error.InvalidMaterializedReference;
        const sid = before_sem.symbol_ids[raw] orelse return error.InvalidMaterializedReference;
        if (sid != @backingInt(reference.symbol_id) or before_ast.nodes.items[raw].tag != .identifier_reference)
            return error.InvalidMaterializedReference;
        const value = values.get(sid) orelse return error.InvalidMaterializedReference;
        const after = after_ast.nodes.items[raw];
        const text = switch (value.kind) {
            .true_ => if (after.tag == .boolean_literal) "true" else return error.InvalidMaterializedNode,
            .false_ => if (after.tag == .boolean_literal) "false" else return error.InvalidMaterializedNode,
            .null_ => if (after.tag == .null_literal) "null" else return error.InvalidMaterializedNode,
            .number => if (after.tag == .numeric_literal) value.number_text else return error.InvalidMaterializedNode,
            else => return error.InvalidMaterializedNode,
        };
        if (!std.mem.eql(u8, after_ast.getText(after.span), text) or after.data.none != 0)
            return error.InvalidMaterializedNode;
        try captured.append(a, .{
            .node = reference.node_index,
            .before_node = before_ast.nodes.items[raw],
            .after_node = after,
            .before_reference = reference,
            .before_symbol_id = sid,
        });
    }
    if (captured.items.len != nodes.len) return error.InvalidMaterializedReference;
    return captured.toOwnedSlice(a);
}

/// Empty providers on an already baked module mean unknown dependencies, not
/// an empty complete set. Unknown is absorbing across later successful bakes.
/// Allocation failure retains the existing conservative store-eviction policy.
fn prepareConstProviderPaths(m: *const Module, collector: *const Linker.ConstProviderCollector) []const []const u8 {
    if (collector.incomplete or (m.const_baked and m.const_providers.len == 0)) return &.{};
    const arena = m.parse_arena orelse return &.{};
    const a = arena.allocator();
    return prepareConstProviderPathsWithAllocator(a, m, collector);
}

fn prepareConstProviderPathsWithAllocator(a: std.mem.Allocator, m: *const Module, collector: *const Linker.ConstProviderCollector) []const []const u8 {
    if (collector.incomplete or (m.const_baked and m.const_providers.len == 0)) return &.{};
    const old = if (m.const_baked) m.const_providers else &.{};
    const capacity = std.math.add(usize, old.len, collector.paths.count()) catch return &.{};
    if (capacity == 0) return &.{};
    const result = a.alloc([]const u8, capacity) catch return &.{};
    var len: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    // The map and duplicated payloads share parse-arena ownership. A failed
    // optional collection publishes unknown; no partial list escapes.
    for (old) |path| {
        const entry = seen.getOrPut(a, path) catch return &.{};
        if (entry.found_existing) continue;
        result[len] = a.dupe(u8, path) catch return &.{};
        len += 1;
    }
    var paths = collector.paths.keyIterator();
    while (paths.next()) |path| {
        const entry = seen.getOrPut(a, path.*) catch return &.{};
        if (entry.found_existing) continue;
        result[len] = a.dupe(u8, path.*) catch return &.{};
        len += 1;
    }
    return result[0..len];
}

fn materializeCrossModuleConstFactsForIndex(
    self: *TreeShaker,
    module_index: usize,
    filter: ConstMaterializeFilter,
    const_profile: ConstMaterializeProfile,
) !bool {
    const source = moduleAtMut(self, @intCast(module_index)) orelse return false;
    const arena = source.parse_arena orelse return false;
    return prepareAndPublishConstFactsForIndex(self, module_index, filter, const_profile, arena.allocator());
}

/// Production supplies the actual module arena. OOM tests wrap that same arena
/// allocator; they exercise this identical core, not a simulated error branch.
fn prepareAndPublishConstFactsForIndex(
    self: *TreeShaker,
    module_index: usize,
    filter: ConstMaterializeFilter,
    const_profile: ConstMaterializeProfile,
    persistent: std.mem.Allocator,
) !bool {
    const m = moduleAtMut(self, @intCast(module_index)) orelse return false;
    // Numeric indices are local to one graph. Facts from a different graph
    // cannot authorize this module even when both graphs use the same slots.
    if (self.linker.graph != self.graph or m.index.toU32() != module_index) return false;
    if (self.linker.graph.getModule(m.index) != m) return false;
    if (m.import_bindings.len == 0) return false;
    const sem = m.semantic orelse return false;
    const ast = &(m.ast orelse return false);
    // (#4557 B-precise) provider 경로 수집기. GPA(self.allocator)로 만들고 함수 끝 deinit.
    // buildCrossModuleConstValuesProfiled 가 체인 전체를 채운 뒤, bake 확정 시 parse_arena 로 dupe 해
    // module 에 기록. collector.incomplete(다단 체인 미추적)면 crude-b 폴백.
    var collector: Linker.ConstProviderCollector = .{};
    defer collector.paths.deinit(self.linker.allocator);
    var const_values = blk: {
        var build_scope = profile.beginMaybe(const_profile.build_facts);
        defer build_scope.end();
        const build_profile = if (const_profile.build_facts != null)
            Linker.ConstValuesProfile{
                .resolve = const_profile.build_facts_resolve,
                .lookup = const_profile.build_facts_lookup,
            }
        else
            Linker.ConstValuesProfile{};
        break :blk try self.linker.buildCrossModuleConstValuesProfiled(m, sem, build_profile, &collector);
    };
    defer const_values.deinit(self.linker.allocator);
    // Validate only imports that contributed an actual scalar fact. The
    // scanner-owned declaration/specifier relation is independent of its
    // matching SID and local-node pair; imported properties are not SID names.
    for (m.import_bindings) |ib| {
        const sid = ib.local_symbol.semanticIndex() orelse continue;
        if (!const_values.contains(sid)) continue;
        _ = m.checkedImportBindingLocalName(ib) catch return false;
    }
    const should_materialize = blk: {
        var gate_scope = profile.beginMaybe(const_profile.candidate_gate);
        defer gate_scope.end();
        break :blk shouldMaterializeConstFacts(self, ast, sem, &const_values, filter);
    };
    if (!should_materialize) return false;

    // The installed graph owns this authority. A COW candidate is only the
    // target of the later query and never registers a source identity.
    var runtime_source = (try runtime_witness.capture(self.allocator, self.graph, m)) orelse return false;
    defer runtime_source.deinit(self.allocator);
    var prepared = PreparedConstModule.init(m, self.graph.allocator, persistent) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    defer prepared.discard();
    const candidate = prepared.candidate;
    const candidate_ast = &candidate.ast.?;
    const candidate_sem = candidate.semantic.?;
    // Existing entries are immutable read-query caches for these same node
    // indices. Borrow them; only this operation's cache misses are owned here.
    var scratch = try Scratch.init(self.allocator, 1);
    const borrowed_forbidden = if (self.materialize_scratch) |source_scratch|
        if (module_index < source_scratch.forbidden.len) source_scratch.forbidden[module_index] else null
    else
        null;
    const borrowed_reachable = if (self.materialize_scratch) |source_scratch|
        if (module_index < source_scratch.reachable.len) source_scratch.reachable[module_index] else null
    else
        null;
    scratch.forbidden[0] = borrowed_forbidden;
    scratch.reachable[0] = borrowed_reachable;
    defer {
        if (borrowed_forbidden != null) scratch.forbidden[0] = null;
        if (borrowed_reachable != null) scratch.reachable[0] = null;
        scratch.deinit();
    }
    var new_scratch: ?Scratch = null;
    defer if (new_scratch) |*owned| owned.deinit();
    var eligible_reference_nodes = try materializableReferenceNodes(self.allocator, candidate_ast, candidate_sem);
    defer eligible_reference_nodes.deinit();
    var materialized_nodes: std.ArrayList(NodeIndex) = .empty;
    defer materialized_nodes.deinit(self.allocator);
    const materialized = blk: {
        var materialize_scope = profile.beginMaybe(const_profile.materialize);
        defer materialize_scope.end();
        break :blk constant_facts.materializeWithScratchDetailed(
            self.allocator,
            candidate_ast,
            candidate_sem.symbol_ids,
            &const_values,
            &scratch,
            0,
            const_profile.inner,
            const_profile.policy.skipMinifyIfSafe(),
            &eligible_reference_nodes,
            &materialized_nodes,
        );
    };
    if (!materialized.changed) return false;
    const materialized_reads = captureMaterializedReads(persistent, m, candidate, materialized_nodes.items, &const_values) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };

    // Capture the old completeness state before publishing the new bake.
    const providers = prepareConstProviderPaths(m, &collector);
    candidate.const_baked = true;
    candidate.const_providers = providers;
    // The restored-source receipt certifies its original physical backings.
    // A successful COW mutation retires that proof; no receipt is reissued for
    // an equal clone. The source module retains it on every rejected candidate.
    candidate.self_namespace_source_receipt = null;

    const skip_minify = const_profile.policy.skipMinifyIfSafe() and !materialized.needs_minify;
    var staged_shaker = self.*;
    staged_shaker.materialize_scratch = null;
    const complete = if (skip_minify) blk: {
        if (!materialized.tracked_nodes_complete) break :blk false;
        staged_shaker.graph.resyncModuleMetadataAfterConstMaterializationRetainingGraph(candidate, persistent, materialized_nodes.items) catch |err| {
            if (err == error.OutOfMemory) return err;
            break :blk false;
        };
        try refreshFoldedNumericExportFactsWithAllocator(&staged_shaker, candidate, candidate_ast, persistent);
        candidate.namespace_access_index = null;
        staged_shaker.ast_mutated_after_link = true;
        break :blk true;
    } else prepareJournalConstMinification(&staged_shaker, &prepared, materialized_reads, &runtime_source, const_profile) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    if (!complete) return false;
    if (candidate.semantic.?.symbols.items.len != m.semantic.?.symbols.items.len or
        candidate.semantic.?.scopes.len != m.semantic.?.scopes.len) return false;
    if (skip_minify and self.materialize_scratch == null)
        new_scratch = try Scratch.init(self.allocator, self.graph.moduleCount());
    const publication = (try runtime_registration.preparePublication(self.graph.allocator, self.graph, m, candidate)) orelse return false;
    if (!publication.isCurrent()) return false;
    var exports_publication = self.linker.prepareCanonicalModulePublication(m, candidate) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    defer exports_publication.deinit();
    if (!exports_publication.isCurrent()) return false;
    // No operation below this line allocates or refuses publication. Publish
    // the real Module header before its already-prepared backing registry.
    prepared.publish();
    publication.publishAssumePrepared();
    exports_publication.publishAssumePrepared();
    self.ast_mutated_after_link = staged_shaker.ast_mutated_after_link;
    if (skip_minify) {
        if (new_scratch) |owned| {
            self.materialize_scratch = owned;
            new_scratch = null;
        }
        if (self.materialize_scratch) |*target| {
            if (borrowed_forbidden == null) {
                target.forbidden[module_index] = scratch.forbidden[0];
                scratch.forbidden[0] = null;
            }
            if (borrowed_reachable == null) {
                target.reachable[module_index] = scratch.reachable[0];
                scratch.reachable[0] = null;
            }
        }
    } else {
        if (self.materialize_scratch) |*source_scratch| source_scratch.invalidate(module_index);
        if (module_index < self.import_record_stmt_indices.len) {
            if (self.import_record_stmt_indices[module_index]) |indices| {
                self.allocator.free(indices);
                self.import_record_stmt_indices[module_index] = null;
            }
        }
    }
    return true;
}

fn materializeCrossModuleConstFacts(
    self: *TreeShaker,
    mod_count: usize,
    filter: ConstMaterializeFilter,
    reverse: bool,
    const_profile: ConstMaterializeProfile,
) !bool {
    var any_changed = false;
    if (reverse) {
        var i = mod_count;
        while (i > 0) {
            i -= 1;
            if (try materializeCrossModuleConstFactsForIndex(self, i, filter, const_profile)) any_changed = true;
        }
    } else {
        for (0..mod_count) |i| {
            if (try materializeCrossModuleConstFactsForIndex(self, i, filter, const_profile)) any_changed = true;
        }
    }
    return any_changed;
}

/// Full pre-pass for minify-syntax builds: materialize all proven constants
/// before tree-shaking so dead branches do not seed unnecessary imports.
pub fn materializeFullPrepass(self: *TreeShaker, mod_count: usize) !bool {
    return materializeCrossModuleConstFacts(self, mod_count, .all, false, prepassProfile());
}

fn shouldVisitNumericPostPassModule(self: *const TreeShaker, idx: u32) bool {
    if (self.graph.preserve_modules) return true;
    if (idx >= self.included.capacity()) return false;
    return self.included.isSet(idx);
}

fn enqueueNumericPostPassModule(
    self: *TreeShaker,
    queue: *std.ArrayList(u32),
    queued: *std.DynamicBitSet,
    idx: u32,
    mod_count: usize,
) !void {
    if (idx >= mod_count) return;
    if (!shouldVisitNumericPostPassModule(self, idx)) return;
    const m = getModule(self, idx) orelse return;
    if (m.import_bindings.len == 0) return;
    if (queued.isSet(idx)) return;
    try queue.append(self.allocator, idx);
    queued.set(idx);
}

fn enqueueNumericPostPassImporters(
    self: *TreeShaker,
    queue: *std.ArrayList(u32),
    queued: *std.DynamicBitSet,
    idx: u32,
    mod_count: usize,
) !void {
    const m = getModule(self, idx) orelse return;
    for (m.importers.items) |imp| {
        try enqueueNumericPostPassModule(self, queue, queued, @intCast(@backingInt(imp)), mod_count);
    }
}

/// Post-shake numeric propagation. The queue is kept unique while pending but
/// allows re-enqueue after mutation so later importer effects still propagate.
pub fn materializeNumericConstFactsWorklist(self: *TreeShaker, mod_count: usize) !void {
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(self.allocator);
    var queued = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
    defer queued.deinit();

    const postpass_profile = ConstMaterializeProfile{
        .policy = .numeric_post_pass,
        .build_facts = .shake_numeric_postpass_build_facts,
        .build_facts_resolve = .shake_numeric_postpass_build_facts_resolve,
        .build_facts_lookup = .shake_numeric_postpass_build_facts_lookup,
        .candidate_gate = .shake_numeric_postpass_candidate_gate,
        .materialize = .shake_numeric_postpass_materialize,
        .minify_resync = .shake_numeric_postpass_minify_resync,
        .minify = .shake_numeric_postpass_minify,
        .resync = .shake_numeric_postpass_resync,
        .minify_skip = .shake_numeric_postpass_minify_skip,
        .inner = .{
            .forbidden = .shake_numeric_postpass_forbidden,
            .reachable = .shake_numeric_postpass_reachable,
            .replace = .shake_numeric_postpass_replace,
        },
    };

    {
        var seed_scope = profile.begin(.shake_numeric_postpass_queue_seed);
        defer seed_scope.end();

        for (0..mod_count) |i| {
            try enqueueNumericPostPassModule(self, &queue, &queued, @intCast(i), mod_count);
        }
    }

    {
        var queue_scope = profile.begin(.shake_numeric_postpass_queue);
        defer queue_scope.end();

        while (queue.pop()) |idx| {
            if (idx >= mod_count) continue;
            queued.unset(idx);
            if (!try materializeCrossModuleConstFactsForIndex(self, idx, .numeric, postpass_profile)) continue;
            try enqueueNumericPostPassImporters(self, &queue, &queued, idx, mod_count);
        }
    }
}

fn enqueueStaticImporters(
    self: *TreeShaker,
    queue: *std.ArrayList(u32),
    queued: *std.DynamicBitSet,
    idx: u32,
    mod_count: usize,
) !void {
    const m = getModule(self, idx) orelse return;
    for (m.importers.items) |imp| {
        const ii = @backingInt(imp);
        if (ii >= mod_count) continue;
        if (queued.isSet(ii)) continue;
        try queue.append(self.allocator, @intCast(ii));
        queued.set(ii);
    }
}

/// Numeric pre-pass for non-minify builds. Re-export-only modules are forwarded
/// once to avoid repeatedly enqueuing the same importers.
pub fn propagateNumericExportConstFacts(self: *TreeShaker, mod_count: usize) !void {
    const const_profile = prepassProfile();
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(self.allocator);
    var queued = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
    defer queued.deinit();
    var forwarded_re_exports = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
    defer forwarded_re_exports.deinit();
    {
        var seed_scope = profile.begin(.shake_const_prepass_numeric_seed_scan);
        defer seed_scope.end();

        for (0..mod_count) |i| {
            const m = moduleAtMut(self, @intCast(i)) orelse continue;
            const ast = &(m.ast orelse continue);
            if (try foldNumericExportSeeds(self, m, ast)) {
                try enqueueStaticImporters(self, &queue, &queued, @intCast(i), mod_count);
            }
        }
    }

    {
        var queue_scope = profile.begin(.shake_const_prepass_numeric_queue);
        defer queue_scope.end();

        while (queue.pop()) |idx| {
            if (idx < mod_count) queued.unset(idx);
            if (idx >= mod_count) continue;
            if (try materializeCrossModuleConstFactsForIndex(self, idx, .numeric_export_chain, const_profile)) {
                try enqueueStaticImporters(self, &queue, &queued, idx, mod_count);
                continue;
            }

            if (forwarded_re_exports.isSet(idx)) continue;
            const m = getModule(self, idx) orelse continue;
            var has_re_export = false;
            for (m.export_bindings) |eb| {
                if (eb.kind.isAnyReExport()) {
                    has_re_export = true;
                    break;
                }
            }
            if (!has_re_export) continue;
            forwarded_re_exports.set(idx);
            try enqueueStaticImporters(self, &queue, &queued, idx, mod_count);
        }
    }
}

const MinifiedConstInputMutation = enum {
    none,
    stale_sidecar,
    incomplete_tracking,
    dead_block_local_let,
    dead_block_local_const,
    dead_block_local_var,
    dead_block_module_var,
    dead_block_class_static_var,
    dead_block_var_parameter_merge,
    dead_block_var_escaped_identifier,
    preexisting_detached_block_owner,
    misassigned_dead_block_owner,
    wrong_dead_block_owner_tag,
    unsupported_dead_block_function,
    unsupported_dead_block_class,
    unsupported_dead_block_loop,
    unsupported_dead_nested_arrow,
    unsupported_dead_nested_function,
    unsupported_dead_generator,
    unsupported_dead_catch_scope,
    unsupported_dead_class_body_scope,
    unsupported_dead_static_block_scope,
    unsupported_class_static_dead_var,
    unsupported_class_static_dead_var_direct_eval,
    unsupported_class_static_dead_var_external_read,
    unsupported_class_static_dead_var_external_write,
    unsupported_class_static_dead_var_nested_read,
    unsupported_class_static_dead_var_nested_write,
    unsupported_class_static_dead_var_live_redeclaration,
    unsupported_dead_class_static_var_scope,
    unsupported_function_dead_var_external_read,
    unsupported_function_dead_var_external_write,
    unsupported_function_dead_var_nested_read,
    unsupported_function_dead_var_nested_write,
    unsupported_function_dead_var_direct_eval,
    unsupported_function_dead_var_eval_in_dead_block,
    unsupported_function_dead_var_nested_eval,
    unsupported_function_dead_var_duplicate_dead_declaration,
    unsupported_function_dead_var_live_redeclaration,
    unsupported_module_dead_var_direct_eval,
    wrong_dead_var_origin_scope,
    wrong_dead_var_scope_map,
    wrong_dead_var_scope_symbol_count,
    wrong_dead_var_scope_kind,
    wrong_dead_var_with_scope_flag,
    wrong_dead_var_module_strictness,
    wrong_dead_var_static_scope_strictness,
    wrong_dead_var_static_scope_kind,
    wrong_dead_var_static_scope_owner,
    wrong_dead_var_static_scope_foreign_owner,
    wrong_dead_var_static_scope_parent,
    empty_targets,
    none_target,
    duplicate_target,
    out_of_bounds_target,
    missing_target_identity,
    surviving_reference_node,
    wrong_target_identity,
    missing_read_row,
    wrong_read_symbol,
    not_read,
    write_target,
    type_context,
    value_as_type,
    invalid_binding_scope,
    invalid_reference_scope,
    missing_scope_owner,
    wrong_scope_owner,
};

fn expectConstMaterializeGraphHandoff(
    skip_minify: bool,
    mutation: MinifiedConstInputMutation,
    policy: ConstPassPolicy,
) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const unsupported_dead_block_body: ?[]const u8 = switch (mutation) {
        .dead_block_module_var,
        .wrong_dead_var_scope_kind,
        .wrong_dead_var_with_scope_flag,
        .wrong_dead_var_module_strictness,
        => "var local=value; console.log(local);",
        .unsupported_dead_block_function => "function local(){return value;} console.log(local());",
        .unsupported_dead_block_class => "class Local {} console.log(Local);",
        .unsupported_dead_block_loop => "for(let local=0;local<1;local++){console.log(value);}",
        .unsupported_dead_nested_arrow => "const local=()=>value; console.log(local());",
        .unsupported_dead_nested_function => "const local=function(){return value;}; console.log(local());",
        .unsupported_dead_generator => "function* local(){yield value;} console.log(local().next().value);",
        .unsupported_dead_catch_scope => "try{throw value;}catch(local){console.log(local);}",
        .unsupported_dead_class_body_scope => "class Local { method(){return value;} } console.log(Local);",
        .unsupported_dead_static_block_scope => "class Local { static { const local=value; console.log(local); } }",
        .unsupported_class_static_dead_var => "class Local { static { var local=value; console.log(local); } }",
        else => null,
    };
    const unsupported_function_dead_var_body: ?[]const u8 = switch (mutation) {
        .unsupported_function_dead_var_external_read,
        .unsupported_function_dead_var_external_write,
        .unsupported_function_dead_var_nested_read,
        .unsupported_function_dead_var_nested_write,
        .unsupported_function_dead_var_direct_eval,
        .unsupported_function_dead_var_nested_eval,
        .unsupported_function_dead_var_live_redeclaration,
        => "var local=value; console.log(local);",
        .unsupported_function_dead_var_duplicate_dead_declaration => "var local; var local; console.log(local);",
        .wrong_dead_var_origin_scope,
        .wrong_dead_var_scope_map,
        .wrong_dead_var_scope_symbol_count,
        .wrong_dead_var_scope_kind,
        .wrong_dead_var_with_scope_flag,
        => "var local=value; console.log(local);",
        else => null,
    };
    const unsupported_function_dead_var_tail: []const u8 = switch (mutation) {
        .unsupported_function_dead_var_external_read => "return local + value + input;",
        .unsupported_function_dead_var_external_write => "local=value; return value + input;",
        .unsupported_function_dead_var_nested_read => "function nested(){return local;} return nested() + value + input;",
        .unsupported_function_dead_var_nested_write => "function nested(){local=value;} nested(); return value + input;",
        .unsupported_function_dead_var_direct_eval => "eval('local'); return value + input;",
        .unsupported_function_dead_var_nested_eval => "function nested(){eval('local');} nested(); return value + input;",
        .unsupported_function_dead_var_live_redeclaration => "var local; return value + input;",
        .dead_block_var_parameter_merge => "console.log(value + 2); return local + value + input;",
        .dead_block_var_escaped_identifier => "console.log(value + 2); return value + input;",
        else => "return value + input;",
    };
    const dead_function_var_body = if (mutation == .unsupported_function_dead_var_eval_in_dead_block)
        "var local=value; eval('local'); console.log(local);"
    else if (mutation == .wrong_dead_var_scope_map)
        "var lo\\u0063al=value; console.log(local);"
    else if (mutation == .dead_block_var_escaped_identifier)
        "var lo\\u0063al=value; console.log(local);"
    else if (mutation == .dead_block_var_parameter_merge)
        "var local=value; console.log(local);"
    else
        unsupported_function_dead_var_body;
    const class_static_var_tail: []const u8 = switch (mutation) {
        .unsupported_class_static_dead_var_direct_eval => "eval('local');",
        .unsupported_class_static_dead_var_external_read => "console.log(local);",
        .unsupported_class_static_dead_var_external_write => "local=value;",
        .unsupported_class_static_dead_var_nested_read => "function nested(){return local;} console.log(nested());",
        .unsupported_class_static_dead_var_nested_write => "function nested(){local=value;} nested();",
        .unsupported_class_static_dead_var_live_redeclaration => "var local;",
        else => "",
    };
    const class_static_foreign_block: []const u8 = if (mutation == .wrong_dead_var_static_scope_foreign_owner)
        "static { console.log('scope-owner-decoy'); }"
    else
        "";
    const class_static_parent_decoy: []const u8 = if (mutation == .wrong_dead_var_static_scope_parent)
        "class Decoy { static { console.log('scope-parent-decoy'); } }"
    else
        "";
    const source = if (mutation == .unsupported_module_dead_var_direct_eval)
        "export const value=7; if(value - 7) { var local=value; console.log(local); } eval('local'); console.log(value + 2); export function read(input){return value + input;}"
    else if (mutation == .unsupported_dead_class_static_var_scope)
        "export const value=7; if(value - 7) { class Local { static { var local=value; console.log('dead',local); } } } console.log(value+2); export function read(input){return value+input;}"
    else if (mutation == .dead_block_class_static_var or
        mutation == .unsupported_class_static_dead_var_direct_eval or
        mutation == .unsupported_class_static_dead_var_external_read or
        mutation == .unsupported_class_static_dead_var_external_write or
        mutation == .unsupported_class_static_dead_var_nested_read or
        mutation == .unsupported_class_static_dead_var_nested_write or
        mutation == .unsupported_class_static_dead_var_live_redeclaration or
        mutation == .wrong_dead_var_static_scope_strictness or
        mutation == .wrong_dead_var_static_scope_kind or
        mutation == .wrong_dead_var_static_scope_owner or
        mutation == .wrong_dead_var_static_scope_foreign_owner or
        mutation == .wrong_dead_var_static_scope_parent)
        try std.fmt.allocPrint(
            arena_alloc,
            "export const value=7; {s} class Local {{ static {{ if(value - 7) {{ var local=value; console.log('dead',local); }} {s} console.log(value + 2); }} {s} }} export function read(input){{return value + input;}}",
            .{ class_static_parent_decoy, class_static_var_tail, class_static_foreign_block },
        )
    else if (dead_function_var_body) |body|
        try std.fmt.allocPrint(
            arena_alloc,
            "export const value=7; export function read({s}){{if(value - 7) {{{s}}} {s}}}",
            .{
                if (mutation == .dead_block_var_parameter_merge) "local" else "input",
                body,
                unsupported_function_dead_var_tail,
            },
        )
    else if (mutation == .dead_block_local_var and policy == .numeric_post_pass)
        "export const value=7; export function read(input){if(value - 7) { var local=value; console.log(local); } console.log(value + 2); return value + input;}"
    else if (unsupported_dead_block_body) |body|
        try std.fmt.allocPrint(
            arena_alloc,
            "export const value=7; if(value - 7) {{{s}}} console.log(value + 2); export function read(input){{return value + input;}}",
            .{body},
        )
    else if (mutation == .dead_block_local_let)
        "export const value=7; if(value - 7) { let local=value; console.log(local); } console.log(value + 2); export function read(input){return value + input;}"
    else if (mutation == .dead_block_local_const)
        "export const value=7; if(value - 7) { const local=value; console.log(local); } console.log(value + 2); export function read(input){return value + input;}"
    else if (mutation == .preexisting_detached_block_owner)
        "export const value=7; if(false) { console.log(value); } console.log(value + 2); export function read(input){return value + input;}"
    else if (mutation == .misassigned_dead_block_owner or mutation == .wrong_dead_block_owner_tag)
        "export const value=7; if(value - 7) { console.log(value); } console.log(value + 2); export function read(input){return value + input;}"
    else if (skip_minify)
        "const value=7; if(false) console.log(value); console.log(value); function read(){return value;}"
    else if (policy == .pre_pass)
        "export const value=7; console.log(value + 2, readAlias()); export function read(input){return value + input;} function readAlias(){const local=value;return local;}"
    else
        "export const value=7; if(value - 7) { console.log(value); } console.log(value + 2); export function read(input){return value + input;}";

    const Scanner = @import("../../lexer/scanner.zig").Scanner;
    const Parser = @import("../../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    const minify_mod = @import("../../transformer/minify.zig");
    const ModuleGraph = @import("../graph.zig").ModuleGraph;
    const ResolveCache = @import("../resolve_cache.zig").ResolveCache;

    var scanner = try Scanner.init(arena_alloc, source);
    scanner.is_module = true;
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_exact_declaration_anchors = !skip_minify;
    try analyzer.analyze();

    if (mutation == .wrong_dead_block_owner_tag) {
        var owner_found = false;
        for (parser.ast.nodes.items) |node| {
            if (node.tag != .if_statement or node.data.ternary.b.isNone()) continue;
            const owner = @backingInt(node.data.ternary.b);
            if (owner >= parser.ast.nodes.items.len or parser.ast.nodes.items[owner].tag != .block_statement) continue;
            parser.ast.nodes.items[owner] = .{
                .tag = .empty_statement,
                .span = parser.ast.nodes.items[owner].span,
                .data = .{ .none = 0 },
            };
            owner_found = true;
            break;
        }
        if (!owner_found) return error.MissingDeadBlockOwner;
    }

    if (mutation == .misassigned_dead_block_owner) {
        var dead_owner: ?u32 = null;
        var dead_scope: ?u32 = null;
        for (parser.ast.nodes.items) |node| {
            if (node.tag != .if_statement or node.data.ternary.b.isNone()) continue;
            const owner = @backingInt(node.data.ternary.b);
            if (owner >= parser.ast.nodes.items.len or parser.ast.nodes.items[owner].tag != .block_statement) continue;
            dead_owner = owner;
            dead_scope = analyzer.scope_owner_map.get(owner) orelse return error.MissingDeadBlockScope;
            break;
        }
        const owner = dead_owner orelse return error.MissingDeadBlockOwner;
        const scope = dead_scope orelse return error.MissingDeadBlockScope;
        var alternate_scope: ?u32 = null;
        var owners = analyzer.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != scope) {
                alternate_scope = entry.value_ptr.*;
                break;
            }
        }
        try analyzer.scope_owner_map.put(arena_alloc, owner, alternate_scope orelse return error.MissingAlternateScope);
    }

    var value_symbol: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        if (symbol.kind == .variable_const and std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) {
            value_symbol = @intCast(index);
            break;
        }
    }
    const value_id = value_symbol orelse return error.MissingValueSymbol;

    var dead_local_symbol_id: ?u32 = null;
    var dead_local_binding: ?NodeIndex = null;
    if (mutation == .dead_block_local_let or mutation == .dead_block_local_const or
        (mutation == .dead_block_local_var and policy == .numeric_post_pass) or
        mutation == .dead_block_module_var or
        (mutation == .dead_block_class_static_var and policy == .numeric_post_pass) or
        mutation == .unsupported_class_static_dead_var_direct_eval or
        mutation == .unsupported_class_static_dead_var_external_read or
        mutation == .unsupported_class_static_dead_var_external_write or
        mutation == .unsupported_class_static_dead_var_nested_read or
        mutation == .unsupported_class_static_dead_var_nested_write or
        mutation == .unsupported_class_static_dead_var_live_redeclaration or
        mutation == .dead_block_var_parameter_merge or
        mutation == .dead_block_var_escaped_identifier or
        mutation == .wrong_dead_var_origin_scope or mutation == .wrong_dead_var_scope_map or
        mutation == .wrong_dead_var_scope_symbol_count or mutation == .wrong_dead_var_scope_kind or
        mutation == .wrong_dead_var_with_scope_flag or mutation == .wrong_dead_var_module_strictness or
        mutation == .wrong_dead_var_static_scope_strictness or
        mutation == .wrong_dead_var_static_scope_kind or
        mutation == .wrong_dead_var_static_scope_owner or
        mutation == .wrong_dead_var_static_scope_foreign_owner or
        mutation == .wrong_dead_var_static_scope_parent)
    {
        for (analyzer.symbols.items, 0..) |symbol, index| {
            const name = symbol.nameText(parser.ast.source);
            if (std.mem.eql(u8, name, "local") or
                ((mutation == .wrong_dead_var_scope_map or mutation == .dead_block_var_escaped_identifier) and
                    std.mem.eql(u8, name, "lo\\u0063al")))
            {
                dead_local_symbol_id = @intCast(index);
                break;
            }
        }
        const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .binding_identifier and raw < analyzer.symbol_ids.items.len and
                analyzer.symbol_ids.items[raw] == local_id)
            {
                dead_local_binding = @fromBackingInt(@intCast(raw));
                break;
            }
        }
        if (dead_local_binding == null) return error.MissingDeadLocalBinding;
    }

    if (policy == .numeric_post_pass) switch (mutation) {
        .wrong_dead_var_origin_scope => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            analyzer.symbols.items[local_id].origin_scope = @fromBackingInt(@as(u32, 0));
        },
        .wrong_dead_var_scope_map => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            _ = analyzer.scope_maps.items[scope].remove(analyzer.symbols.items[local_id].nameText(parser.ast.source));
        },
        .wrong_dead_var_scope_symbol_count => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            analyzer.scopes.items[scope].symbol_count -= 1;
        },
        .wrong_dead_var_scope_kind => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            analyzer.scopes.items[scope].kind = .global;
        },
        .wrong_dead_var_with_scope_flag => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            analyzer.scopes.items[scope].subtree_has_with = true;
        },
        .wrong_dead_var_module_strictness => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            analyzer.scopes.items[scope].is_strict = false;
        },
        .wrong_dead_var_static_scope_strictness => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            analyzer.scopes.items[scope].is_strict = false;
        },
        .wrong_dead_var_static_scope_kind => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope = analyzer.symbols.items[local_id].scope_id.toIndex();
            analyzer.scopes.items[scope].kind = .function;
        },
        .wrong_dead_var_static_scope_owner => {
            var owner_found = false;
            for (parser.ast.nodes.items, 0..) |node, raw| {
                if (node.tag != .static_block) continue;
                if (analyzer.scope_owner_map.remove(@intCast(raw))) {
                    owner_found = true;
                    break;
                }
            }
            if (!owner_found) return error.MissingStaticBlockScopeOwner;
        },
        .wrong_dead_var_static_scope_foreign_owner => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const target_scope: u32 = @intCast(analyzer.symbols.items[local_id].scope_id.toIndex());
            var target_owner: ?u32 = null;
            var foreign_owner: ?u32 = null;
            var foreign_scope: ?u32 = null;
            var owners = analyzer.scope_owner_map.iterator();
            while (owners.next()) |entry| {
                const raw = entry.key_ptr.*;
                if (raw >= parser.ast.nodes.items.len or parser.ast.nodes.items[raw].tag != .static_block) continue;
                if (entry.value_ptr.* == target_scope) {
                    target_owner = raw;
                } else if (foreign_owner == null) {
                    foreign_owner = raw;
                    foreign_scope = entry.value_ptr.*;
                }
            }
            const target = target_owner orelse return error.MissingStaticBlockScopeOwner;
            const foreign = foreign_owner orelse return error.MissingForeignStaticBlockScopeOwner;
            const other_scope = foreign_scope orelse return error.MissingForeignStaticBlockScopeOwner;
            if (!analyzer.scope_owner_map.contains(target) or
                !analyzer.scope_owner_map.contains(foreign)) return error.MissingStaticBlockScopeOwner;
            _ = analyzer.scope_owner_map.remove(target);
            _ = analyzer.scope_owner_map.remove(foreign);
            try analyzer.scope_owner_map.put(arena_alloc, target, other_scope);
            try analyzer.scope_owner_map.put(arena_alloc, foreign, target_scope);
        },
        .wrong_dead_var_static_scope_parent => {
            const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
            const scope_id = analyzer.symbols.items[local_id].scope_id;
            const original_parent = analyzer.scopes.items[scope_id.toIndex()].parent;
            var foreign_class_body: ?u32 = null;
            for (analyzer.scopes.items, 0..) |scope, raw| {
                if (scope.kind == .class_body and @as(u32, @intCast(raw)) != @backingInt(original_parent)) {
                    foreign_class_body = @intCast(raw);
                    break;
                }
            }
            analyzer.scopes.items[scope_id.toIndex()].parent = @fromBackingInt(
                foreign_class_body orelse return error.MissingForeignClassBodyScope,
            );
        },
        else => {},
    };

    var expected_elided_block_owner: ?u32 = null;
    var expected_elided_block_scope: ?u32 = null;
    if (policy == .numeric_post_pass and !skip_minify and mutation != .wrong_dead_block_owner_tag) {
        for (parser.ast.nodes.items) |node| {
            if (node.tag != .if_statement or node.data.ternary.b.isNone()) continue;
            const consequent = @backingInt(node.data.ternary.b);
            if (consequent >= parser.ast.nodes.items.len or
                parser.ast.nodes.items[consequent].tag != .block_statement) continue;
            expected_elided_block_owner = consequent;
            expected_elided_block_scope = analyzer.scope_owner_map.get(consequent) orelse
                return error.MissingDeadBlockScope;
            break;
        }
        if (expected_elided_block_owner == null) return error.MissingDeadBlockOwner;
    }

    // This field is graph-owned naming metadata. A full analyzer rebuild drops
    // it, so preserving it proves this call took the same-graph path.
    analyzer.symbols.items[value_id].output_name_hint = "retained-graph-marker";
    if (mutation == .dead_block_var_parameter_merge) {
        const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
        analyzer.symbols.items[local_id].output_name_hint = "retained-parameter-marker";
    }
    if (policy == .pre_pass) analyzer.symbols.items[value_id].const_kind = .none;
    var local_alias_id: ?u32 = null;
    var local_alias_binding: ?NodeIndex = null;
    if (policy == .pre_pass) {
        for (analyzer.symbols.items, 0..) |symbol, index| {
            if (symbol.kind == .variable_const and std.mem.eql(u8, parser.ast.getText(symbol.name), "local")) {
                local_alias_id = @intCast(index);
                break;
            }
        }
        const alias_id = local_alias_id orelse return error.MissingLocalAliasSymbol;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .binding_identifier and raw < analyzer.symbol_ids.items.len and
                analyzer.symbol_ids.items[raw] == alias_id)
            {
                local_alias_binding = @fromBackingInt(@intCast(raw));
                break;
            }
        }
        if (local_alias_binding == null) return error.MissingLocalAliasBinding;
    }
    var module = Module.init(@fromBackingInt(@as(u32, 0)), "test.js");
    module.source = source;
    module.ast = parser.ast;
    module.parse_arena = &arena;
    module.semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .namespace_member_owners = analyzer.namespace_member_owners,
        .namespace_declaration_owners = analyzer.namespace_declaration_owners,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
        .helper_scope_map = analyzer.helper_scope_map,
    };

    const prepass_ref_deltas = try arena_alloc.alloc(u32, module.semantic.?.symbols.items.len);
    @memset(prepass_ref_deltas, 0);
    module.transform_cache = .{
        .runtime_helpers = .{},
        .symbol_ids = module.semantic.?.symbol_ids,
        .ref_deltas = prepass_ref_deltas,
    };
    if (mutation == .stale_sidecar) {
        module.transform_cache.?.explicit_global_ref_nodes = &.{std.math.maxInt(u32)};
    }
    var prepass_minify_ctx = minify_mod.MinifyCtx.fromSemantic(
        &module.semantic.?,
        module.semantic.?.symbol_ids,
        false,
    );
    prepass_minify_ctx.ref_deltas = prepass_ref_deltas;
    const root: NodeIndex = module.ast.?.transformed_root orelse @fromBackingInt(
        @intCast(module.ast.?.nodes.items.len - 1),
    );
    minify_mod.minify(&module.ast.?, prepass_minify_ctx, arena_alloc, root);
    if (skip_minify) try std.testing.expect(prepass_ref_deltas[value_id] > 0);

    const reachable_nodes = try ast_walk.collectReachableNodeIndices(allocator, &module.ast.?);
    defer allocator.free(reachable_nodes);
    var materialized_nodes: std.ArrayList(NodeIndex) = .empty;
    var materialized: constant_facts.MaterializeResult = .{
        .changed = true,
        .tracked_nodes_complete = true,
    };
    if (policy == .pre_pass) {
        var const_values: std.AutoHashMapUnmanaged(u32, ConstValue) = .empty;
        defer const_values.deinit(arena_alloc);
        try const_values.put(arena_alloc, value_id, .{ .kind = .number, .number_text = "7" });
        materialized = constant_facts.materializeWithScratchDetailed(
            arena_alloc,
            &module.ast.?,
            module.semantic.?.symbol_ids,
            &const_values,
            null,
            0,
            .{},
            false,
            null,
            &materialized_nodes,
        );
        if (!materialized.changed or !materialized.tracked_nodes_complete) return error.MaterializationNotTracked;
    } else {
        for (reachable_nodes) |raw| {
            if (raw >= module.semantic.?.symbol_ids.len) continue;
            if (module.ast.?.nodes.items[raw].tag != .identifier_reference) continue;
            if (module.semantic.?.symbol_ids[raw] != value_id) continue;
            const node_index: NodeIndex = @fromBackingInt(@intCast(raw));
            try materialized_nodes.append(arena_alloc, node_index);
            if (skip_minify) break;
        }
    }
    if (materialized_nodes.items.len == 0) return error.MissingReachableValueReference;
    const valid_materialized_nodes = try arena_alloc.dupe(NodeIndex, materialized_nodes.items);
    if (!skip_minify) {
        const target_node = materialized_nodes.items[0];
        const target_raw = @backingInt(target_node);
        var target_reference_row: ?usize = null;
        for (analyzer.references.items, 0..) |reference, index| {
            if (!reference.flags.declare and reference.node_index == target_node) {
                target_reference_row = index;
                break;
            }
        }
        const reference_row = target_reference_row orelse return error.MissingTargetReferenceRow;
        var untouched_reference_row: ?usize = null;
        for (analyzer.references.items, 0..) |reference, index| {
            if (reference.flags.declare or reference.node_index.isNone()) continue;
            var materialized_reference = false;
            for (valid_materialized_nodes) |materialized_node| {
                if (reference.node_index == materialized_node) {
                    materialized_reference = true;
                    break;
                }
            }
            if (!materialized_reference) {
                untouched_reference_row = index;
                break;
            }
        }
        const other_symbol = if (value_id == 0) @as(u32, 1) else @as(u32, 0);
        if (other_symbol >= analyzer.symbols.items.len) return error.MissingDistinctTargetSymbol;
        switch (mutation) {
            .none,
            .stale_sidecar,
            .incomplete_tracking,
            .dead_block_local_let,
            .dead_block_local_const,
            .dead_block_local_var,
            .dead_block_class_static_var,
            .preexisting_detached_block_owner,
            .misassigned_dead_block_owner,
            .wrong_dead_block_owner_tag,
            .dead_block_module_var,
            .unsupported_dead_block_function,
            .unsupported_dead_block_class,
            .unsupported_dead_block_loop,
            .unsupported_dead_nested_arrow,
            .unsupported_dead_nested_function,
            .unsupported_dead_generator,
            .unsupported_dead_catch_scope,
            .unsupported_dead_class_body_scope,
            .unsupported_dead_static_block_scope,
            .unsupported_dead_class_static_var_scope,
            .unsupported_class_static_dead_var,
            .unsupported_class_static_dead_var_direct_eval,
            .unsupported_class_static_dead_var_external_read,
            .unsupported_class_static_dead_var_external_write,
            .unsupported_class_static_dead_var_nested_read,
            .unsupported_class_static_dead_var_nested_write,
            .unsupported_class_static_dead_var_live_redeclaration,
            .unsupported_function_dead_var_external_read,
            .unsupported_function_dead_var_external_write,
            .unsupported_function_dead_var_nested_read,
            .unsupported_function_dead_var_nested_write,
            .unsupported_function_dead_var_direct_eval,
            .unsupported_function_dead_var_eval_in_dead_block,
            .unsupported_function_dead_var_nested_eval,
            .unsupported_function_dead_var_duplicate_dead_declaration,
            .unsupported_function_dead_var_live_redeclaration,
            .wrong_dead_var_origin_scope,
            .wrong_dead_var_scope_map,
            .wrong_dead_var_scope_symbol_count,
            .dead_block_var_parameter_merge,
            .dead_block_var_escaped_identifier,
            .unsupported_module_dead_var_direct_eval,
            .wrong_dead_var_scope_kind,
            .wrong_dead_var_with_scope_flag,
            .wrong_dead_var_module_strictness,
            .wrong_dead_var_static_scope_strictness,
            .wrong_dead_var_static_scope_kind,
            .wrong_dead_var_static_scope_owner,
            .wrong_dead_var_static_scope_foreign_owner,
            .wrong_dead_var_static_scope_parent,
            => {},
            .empty_targets => materialized_nodes.clearRetainingCapacity(),
            .none_target => materialized_nodes.items[0] = .none,
            .duplicate_target => try materialized_nodes.append(arena_alloc, target_node),
            .out_of_bounds_target => materialized_nodes.items[0] = @fromBackingInt(
                @as(u32, @intCast(module.ast.?.nodes.items.len + 1)),
            ),
            .missing_target_identity => {
                var unbound_literal: ?NodeIndex = null;
                for (reachable_nodes) |raw| {
                    if (raw >= module.semantic.?.symbol_ids.len or
                        module.semantic.?.symbol_ids[raw] != null or
                        module.ast.?.nodes.items[raw].tag != .numeric_literal) continue;
                    unbound_literal = @fromBackingInt(@intCast(raw));
                    break;
                }
                materialized_nodes.items[0] = unbound_literal orelse return error.MissingUnboundNumericLiteral;
            },
            .surviving_reference_node => {
                const span = try module.ast.?.addString("value");
                module.ast.?.nodes.items[target_raw] = .{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                };
            },
            .wrong_target_identity => analyzer.symbol_ids.items[target_raw] = other_symbol,
            .missing_read_row => analyzer.references.items[reference_row].node_index = .none,
            .wrong_read_symbol => analyzer.references.items[reference_row].symbol_id = @fromBackingInt(other_symbol),
            .not_read => analyzer.references.items[reference_row].flags.read = false,
            .write_target => analyzer.references.items[reference_row].flags.write = true,
            .type_context => analyzer.references.items[reference_row].flags.type_context = true,
            .value_as_type => analyzer.references.items[reference_row].flags.value_as_type = true,
            .invalid_binding_scope => analyzer.symbols.items[value_id].scope_id = .none,
            .invalid_reference_scope => {
                const untouched_index = untouched_reference_row orelse return error.MissingUntouchedReference;
                analyzer.references.items[untouched_index].scope_id = .none;
            },
            .missing_scope_owner, .wrong_scope_owner => {
                var program_owner: ?u32 = null;
                for (module.ast.?.nodes.items, 0..) |node, raw| {
                    if (node.tag == .program) {
                        program_owner = @intCast(raw);
                        break;
                    }
                }
                const owner = program_owner orelse return error.MissingProgramScopeOwner;
                if (mutation == .missing_scope_owner) {
                    _ = analyzer.scope_owner_map.remove(owner);
                } else {
                    try analyzer.scope_owner_map.put(
                        arena_alloc,
                        owner,
                        @intCast(analyzer.scopes.items.len + 1),
                    );
                }
            },
        }
    }
    if (policy != .pre_pass and mutation != .surviving_reference_node) {
        for (valid_materialized_nodes) |materialized_index| {
            const literal_span = try module.ast.?.addString("7");
            module.ast.?.nodes.items[@backingInt(materialized_index)] = .{
                .tag = .numeric_literal,
                .span = literal_span,
                .data = .{ .none = 0 },
            };
        }
    }

    var graph_arena = std.heap.ArenaAllocator.init(allocator);
    defer graph_arena.deinit();
    const graph_allocator = graph_arena.allocator();
    var resolve_cache = ResolveCache.init(graph_allocator, .{});
    defer resolve_cache.deinit();
    var graph = ModuleGraph.init(graph_allocator, &resolve_cache);
    defer graph.deinit();
    graph.transform_options_base.minify_syntax = !skip_minify;
    var linker = Linker.init(graph_allocator, &graph, .esm);
    defer linker.deinit();
    var shaker = try TreeShaker.init(graph_allocator, &graph, &linker);
    defer shaker.deinit();
    if (mutation == .incomplete_tracking) materialized.tracked_nodes_complete = false;

    const retained = try minifyAndResyncModule(
        &shaker,
        &module,
        module.semantic.?,
        &module.ast.?,
        .{ .policy = policy },
        materialized,
        materialized_nodes.items,
        skip_minify,
    );

    if (policy == .pre_pass and mutation == .none) {
        try std.testing.expectEqual(@as(usize, 2), module.export_bindings.len);
    }
    const semantic = &module.semantic.?;
    const expect_dead_local_graph = mutation == .dead_block_local_let or mutation == .dead_block_local_const or
        (mutation == .dead_block_local_var and policy == .numeric_post_pass) or
        mutation == .dead_block_module_var or
        mutation == .dead_block_class_static_var or
        mutation == .dead_block_var_escaped_identifier;
    const expect_var_parameter_merge = mutation == .dead_block_var_parameter_merge;
    if (mutation != .none and !expect_dead_local_graph and !expect_var_parameter_merge) {
        // This low-level probe starts after the caller's literal mutation.
        // Rejection now leaves graph publication to the outer transaction;
        // it must not recreate semantic identities by reanalysis.
        try std.testing.expect(!retained);
        try std.testing.expectEqualStrings("retained-graph-marker", semantic.symbols.items[value_id].output_name_hint);
        try std.testing.expect(module.prebuilt_stmt_info == null);
        try std.testing.expect(!shaker.ast_mutated_after_link);
        return;
    }
    try std.testing.expectEqualStrings("retained-graph-marker", semantic.symbols.items[value_id].output_name_hint);
    if (expect_var_parameter_merge) {
        const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
        const local_symbol = semantic.symbols.items[local_id];
        try std.testing.expectEqual(SymbolKind.parameter, local_symbol.kind);
        try std.testing.expectEqualStrings("retained-parameter-marker", local_symbol.output_name_hint);
        try std.testing.expectEqual(@as(u32, 1), local_symbol.reference_count);
        try std.testing.expectEqual(@as(u32, 0), local_symbol.write_count);
        try std.testing.expectEqual(
            @as(?usize, @intCast(local_id)),
            semantic.scope_maps[local_symbol.scope_id.toIndex()].get("local"),
        );
    }
    if (expected_elided_block_owner) |owner| {
        const scope_id = expected_elided_block_scope orelse return error.MissingDeadBlockScope;
        try std.testing.expect(!semantic.scope_owner_map.contains(owner));
        try std.testing.expectEqual(analyzer.scopes.items[scope_id].kind, semantic.scopes[scope_id].kind);
        try std.testing.expectEqual(@as(u16, 0), semantic.scopes[scope_id].symbol_count);
        try std.testing.expectEqual(@as(usize, 0), semantic.scope_maps[scope_id].count());
        for (semantic.symbols.items) |symbol| {
            try std.testing.expect(symbol.scope_id != @as(@TypeOf(symbol.scope_id), @fromBackingInt(@intCast(scope_id))));
            try std.testing.expect(symbol.origin_scope != @as(@TypeOf(symbol.origin_scope), @fromBackingInt(@intCast(scope_id))));
        }
        for (semantic.references) |reference| {
            try std.testing.expect(@backingInt(reference.scope_id) != scope_id);
        }
    }
    if (expect_dead_local_graph) {
        const local_id = dead_local_symbol_id orelse return error.MissingDeadLocalSymbol;
        const binding = dead_local_binding orelse return error.MissingDeadLocalBinding;
        const local_symbol = semantic.symbols.items[local_id];
        const scope_id = expected_elided_block_scope orelse return error.MissingDeadBlockScope;
        try std.testing.expectEqual(@as(u32, 0), local_symbol.reference_count);
        try std.testing.expectEqual(@as(u32, 0), local_symbol.write_count);
        if (local_symbol.kind == .variable_var) {
            const var_scope = analyzer.symbols.items[local_id].scope_id;
            try std.testing.expectEqual(var_scope, local_symbol.scope_id);
            try std.testing.expectEqual(var_scope, local_symbol.origin_scope);
            try std.testing.expectEqual(
                analyzer.scopes.items[var_scope.toIndex()].symbol_count - 1,
                semantic.scopes[var_scope.toIndex()].symbol_count,
            );
            try std.testing.expectEqual(@as(?usize, null), semantic.scope_maps[var_scope.toIndex()].get("local"));
            if (mutation == .dead_block_var_escaped_identifier) {
                try std.testing.expectEqual(
                    @as(?usize, null),
                    semantic.scope_maps[var_scope.toIndex()].get("lo\\u0063al"),
                );
            }
        } else {
            const parent_scope = analyzer.scopes.items[scope_id].parent;
            try std.testing.expectEqual(parent_scope, local_symbol.scope_id);
            try std.testing.expectEqual(parent_scope, local_symbol.origin_scope);
        }
        try std.testing.expectEqual(@as(?u32, null), semantic.symbol_ids[@backingInt(binding)]);
        try std.testing.expectEqual(@as(?usize, null), semantic.scope_maps[scope_id].get("local"));
        for (semantic.references) |reference| try std.testing.expect(@backingInt(reference.symbol_id) != local_id);
    }
    try std.testing.expectEqual(semantic.symbol_ids.ptr, module.transform_cache.?.symbol_ids.ptr);
    for (materialized_nodes.items) |materialized_index| {
        try std.testing.expect(semantic.symbol_ids[@backingInt(materialized_index)] == null);
    }
    const expected_remaining_refs: u32 = if (skip_minify) 2 else 0;
    var remaining_value_reads: u32 = 0;
    for (semantic.references) |reference| {
        if (reference.flags.declare) continue;
        if (@backingInt(reference.symbol_id) == value_id) remaining_value_reads += 1;
        for (materialized_nodes.items) |materialized_index| {
            try std.testing.expect(reference.node_index != materialized_index);
        }
    }
    try std.testing.expectEqual(expected_remaining_refs, remaining_value_reads);
    try std.testing.expectEqual(expected_remaining_refs, semantic.symbols.items[value_id].reference_count);
    if (skip_minify) try std.testing.expectEqual(@as(usize, 2), semantic.references.len);
    try std.testing.expectEqual(semantic.symbol_ids.len, module.transform_cache.?.symbol_ids.len);
    try std.testing.expectEqual(semantic.symbols.items.len, module.transform_cache.?.ref_deltas.len);
    if (skip_minify) {
        try std.testing.expectEqual(@as(u32, 1), module.transform_cache.?.ref_deltas[value_id]);
        try std.testing.expectEqual(
            @as(u32, 1),
            semantic.symbols.items[value_id].reference_count - module.transform_cache.?.ref_deltas[value_id],
        );
    } else {
        try std.testing.expectEqual(@as(u32, 0), module.transform_cache.?.ref_deltas[value_id]);
        var folded_nine = false;
        const minified_reachable = ast_walk.collectReachableNodeIndices(allocator, &module.ast.?) catch
            return error.CouldNotWalkMinifiedAst;
        defer allocator.free(minified_reachable);
        for (minified_reachable) |raw| {
            const node = module.ast.?.nodes.items[raw];
            if (node.tag == .numeric_literal and std.mem.eql(u8, module.ast.?.getSourceText(node.span), "9")) {
                folded_nine = true;
                break;
            }
        }
        try std.testing.expect(folded_nine);
    }
    if (local_alias_id) |local_id| {
        try std.testing.expectEqual(@as(u32, 0), semantic.symbols.items[local_id].reference_count);
        const alias_binding = local_alias_binding orelse return error.MissingLocalAliasBinding;
        try std.testing.expectEqual(@as(?u32, null), semantic.symbol_ids[@backingInt(alias_binding)]);
        for (semantic.references) |reference| try std.testing.expect(@backingInt(reference.symbol_id) != local_id);
        var local_binding_is_reachable = false;
        const reachable_after = try ast_walk.collectReachableNodeIndices(allocator, &module.ast.?);
        defer allocator.free(reachable_after);
        for (reachable_after) |raw| {
            const node = module.ast.?.nodes.items[raw];
            if (node.tag != .binding_identifier) continue;
            if (std.mem.eql(u8, module.ast.?.getText(node.span), "local")) local_binding_is_reachable = true;
        }
        try std.testing.expect(!local_binding_is_reachable);
        for (semantic.scope_maps) |scope_map| try std.testing.expect(!scope_map.contains("local"));
    }
    try std.testing.expect(module.prebuilt_stmt_info != null);
    try std.testing.expect(shaker.ast_mutated_after_link);
}

test "numeric post-pass retains graph when prepass ref deltas exist" {
    try expectConstMaterializeGraphHandoff(true, .none, .numeric_post_pass);
}

test "numeric post-pass retains exact graph through syntax folding" {
    try expectConstMaterializeGraphHandoff(false, .none, .numeric_post_pass);
}

test "numeric post-pass rejects without publication when minification strands a graph sidecar" {
    try expectConstMaterializeGraphHandoff(false, .stale_sidecar, .numeric_post_pass);
}

test "numeric post-pass rejects malformed materialized read handoffs" {
    inline for (std.meta.tags(MinifiedConstInputMutation)) |mutation| {
        switch (mutation) {
            .none,
            .stale_sidecar,
            .dead_block_local_var,
            .dead_block_module_var,
            .dead_block_class_static_var,
            .dead_block_var_parameter_merge,
            .dead_block_var_escaped_identifier,
            .dead_block_local_let,
            .dead_block_local_const,
            .preexisting_detached_block_owner,
            .misassigned_dead_block_owner,
            .wrong_dead_block_owner_tag,
            .unsupported_dead_block_function,
            .unsupported_dead_block_class,
            .unsupported_dead_block_loop,
            .unsupported_dead_nested_arrow,
            .unsupported_dead_nested_function,
            .unsupported_dead_generator,
            .unsupported_dead_catch_scope,
            .unsupported_dead_class_body_scope,
            .unsupported_dead_static_block_scope,
            .unsupported_dead_class_static_var_scope,
            .unsupported_class_static_dead_var,
            .unsupported_class_static_dead_var_direct_eval,
            .unsupported_class_static_dead_var_external_read,
            .unsupported_class_static_dead_var_external_write,
            .unsupported_class_static_dead_var_nested_read,
            .unsupported_class_static_dead_var_nested_write,
            .unsupported_class_static_dead_var_live_redeclaration,
            .unsupported_function_dead_var_external_read,
            .unsupported_function_dead_var_external_write,
            .unsupported_function_dead_var_nested_read,
            .unsupported_function_dead_var_nested_write,
            .unsupported_function_dead_var_direct_eval,
            .unsupported_function_dead_var_eval_in_dead_block,
            .unsupported_function_dead_var_nested_eval,
            .unsupported_function_dead_var_duplicate_dead_declaration,
            .unsupported_function_dead_var_live_redeclaration,
            .unsupported_module_dead_var_direct_eval,
            .wrong_dead_var_origin_scope,
            .wrong_dead_var_scope_map,
            .wrong_dead_var_scope_symbol_count,
            .wrong_dead_var_scope_kind,
            .wrong_dead_var_with_scope_flag,
            .wrong_dead_var_module_strictness,
            .wrong_dead_var_static_scope_strictness,
            .wrong_dead_var_static_scope_kind,
            .wrong_dead_var_static_scope_owner,
            .wrong_dead_var_static_scope_foreign_owner,
            .wrong_dead_var_static_scope_parent,
            => {},
            else => try expectConstMaterializeGraphHandoff(false, mutation, .numeric_post_pass),
        }
    }
}

test "numeric post-pass retains the graph after removing dead block let declarations" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_local_let, .numeric_post_pass);
}

test "numeric post-pass retains the graph after removing dead block const declarations" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_local_const, .numeric_post_pass);
}

test "numeric post-pass retains the graph after removing a dead function-scoped var" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_local_var, .numeric_post_pass);
}

test "numeric post-pass retains the graph after removing a dead module-scoped var" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_module_var, .numeric_post_pass);
}

test "numeric post-pass retains the graph after removing a dead class-static-block-scoped var" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_class_static_var, .numeric_post_pass);
}

test "numeric post-pass removes both scope-map keys for an escaped dead var name" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_var_escaped_identifier, .numeric_post_pass);
}

test "numeric post-pass rejects eighteen unsupported dead-block var hazards without publication" {
    const cases = [_]MinifiedConstInputMutation{
        .unsupported_class_static_dead_var,
        .unsupported_class_static_dead_var_direct_eval,
        .unsupported_class_static_dead_var_external_read,
        .unsupported_class_static_dead_var_external_write,
        .unsupported_class_static_dead_var_nested_read,
        .unsupported_class_static_dead_var_nested_write,
        .unsupported_class_static_dead_var_live_redeclaration,
        .unsupported_dead_class_static_var_scope,
        .unsupported_function_dead_var_external_read,
        .unsupported_function_dead_var_external_write,
        .unsupported_function_dead_var_nested_read,
        .unsupported_function_dead_var_nested_write,
        .unsupported_function_dead_var_direct_eval,
        .unsupported_function_dead_var_eval_in_dead_block,
        .unsupported_function_dead_var_nested_eval,
        .unsupported_function_dead_var_duplicate_dead_declaration,
        .unsupported_function_dead_var_live_redeclaration,
        .unsupported_module_dead_var_direct_eval,
    };
    inline for (cases) |mutation| {
        try expectConstMaterializeGraphHandoff(false, mutation, .numeric_post_pass);
    }
}

test "numeric post-pass keeps a parameter identity when a dead var redeclares it" {
    try expectConstMaterializeGraphHandoff(false, .dead_block_var_parameter_merge, .numeric_post_pass);
}

test "numeric post-pass rejects poisoned dead-var scope metadata" {
    const cases = [_]MinifiedConstInputMutation{
        .wrong_dead_var_origin_scope,
        .wrong_dead_var_scope_map,
        .wrong_dead_var_scope_symbol_count,
        .wrong_dead_var_scope_kind,
        .wrong_dead_var_with_scope_flag,
        .wrong_dead_var_module_strictness,
        .wrong_dead_var_static_scope_strictness,
        .wrong_dead_var_static_scope_kind,
        .wrong_dead_var_static_scope_owner,
        .wrong_dead_var_static_scope_foreign_owner,
        .wrong_dead_var_static_scope_parent,
    };
    inline for (cases) |mutation| {
        try expectConstMaterializeGraphHandoff(false, mutation, .numeric_post_pass);
    }
}

test "numeric post-pass rejects other unsupported dead-block declarations without publication" {
    const cases = [_]MinifiedConstInputMutation{
        .unsupported_dead_block_function,
        .unsupported_dead_block_class,
        .unsupported_dead_block_loop,
        .unsupported_dead_nested_arrow,
        .unsupported_dead_nested_function,
        .unsupported_dead_generator,
        .unsupported_dead_catch_scope,
        .unsupported_dead_class_body_scope,
        .unsupported_dead_static_block_scope,
    };
    inline for (cases) |mutation| {
        try expectConstMaterializeGraphHandoff(false, mutation, .numeric_post_pass);
    }
}

test "numeric post-pass rejects a scope owner detached before its snapshot" {
    try expectConstMaterializeGraphHandoff(false, .preexisting_detached_block_owner, .numeric_post_pass);
}

test "numeric post-pass rejects a dead block assigned to a foreign ScopeId" {
    try expectConstMaterializeGraphHandoff(false, .misassigned_dead_block_owner, .numeric_post_pass);
}

test "numeric post-pass rejects a changed dead block owner node kind" {
    try expectConstMaterializeGraphHandoff(false, .wrong_dead_block_owner_tag, .numeric_post_pass);
}

test "full const pre-pass retains the exact graph when minification drops a local const alias" {
    try expectConstMaterializeGraphHandoff(false, .none, .pre_pass);
}

test "full const pre-pass rejects malformed materialized read handoffs" {
    inline for (std.meta.tags(MinifiedConstInputMutation)) |mutation| {
        switch (mutation) {
            .none,
            .dead_block_local_var,
            .dead_block_module_var,
            .dead_block_class_static_var,
            .dead_block_var_parameter_merge,
            .dead_block_var_escaped_identifier,
            .dead_block_local_let,
            .dead_block_local_const,
            .preexisting_detached_block_owner,
            .misassigned_dead_block_owner,
            .wrong_dead_block_owner_tag,
            .unsupported_dead_block_function,
            .unsupported_dead_block_class,
            .unsupported_dead_block_loop,
            .unsupported_dead_nested_arrow,
            .unsupported_dead_nested_function,
            .unsupported_dead_generator,
            .unsupported_dead_catch_scope,
            .unsupported_dead_class_body_scope,
            .unsupported_dead_static_block_scope,
            .unsupported_dead_class_static_var_scope,
            .unsupported_class_static_dead_var,
            .unsupported_class_static_dead_var_direct_eval,
            .unsupported_class_static_dead_var_external_read,
            .unsupported_class_static_dead_var_external_write,
            .unsupported_class_static_dead_var_nested_read,
            .unsupported_class_static_dead_var_nested_write,
            .unsupported_class_static_dead_var_live_redeclaration,
            .unsupported_function_dead_var_external_read,
            .unsupported_function_dead_var_external_write,
            .unsupported_function_dead_var_nested_read,
            .unsupported_function_dead_var_nested_write,
            .unsupported_function_dead_var_direct_eval,
            .unsupported_function_dead_var_eval_in_dead_block,
            .unsupported_function_dead_var_nested_eval,
            .unsupported_function_dead_var_duplicate_dead_declaration,
            .unsupported_function_dead_var_live_redeclaration,
            .unsupported_module_dead_var_direct_eval,
            .wrong_dead_var_origin_scope,
            .wrong_dead_var_scope_map,
            .wrong_dead_var_scope_symbol_count,
            .wrong_dead_var_scope_kind,
            .wrong_dead_var_with_scope_flag,
            .wrong_dead_var_module_strictness,
            .wrong_dead_var_static_scope_strictness,
            .wrong_dead_var_static_scope_kind,
            .wrong_dead_var_static_scope_owner,
            .wrong_dead_var_static_scope_foreign_owner,
            .wrong_dead_var_static_scope_parent,
            => {},
            else => try expectConstMaterializeGraphHandoff(false, mutation, .pre_pass),
        }
    }
}

fn constTransactionValueEqual(before: anytype, after: @TypeOf(before)) bool {
    const T = @TypeOf(before);
    if (comptime T == Node) {
        if (before.tag != after.tag or !std.meta.eql(before.span, after.span)) return false;
        const width = before.tag.dataWidth();
        return std.mem.eql(u8, std.mem.asBytes(&before.data)[0..width], std.mem.asBytes(&after.data)[0..width]);
    } else return switch (@typeInfo(T)) {
        .optional => if (before) |known| if (after) |actual| constTransactionValueEqual(known, actual) else false else after == null,
        .@"struct" => blk: {
            // Erased-import witnesses contain nested optional snapshots;
            // keep following that typed structure until its tagged Node.
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                if (!constTransactionValueEqual(@field(before, name), @field(after, name))) break :blk false;
            }
            break :blk true;
        },
        else => std.meta.eql(before, after),
    };
}

fn constTransactionMapEqual(before: anytype, after: @TypeOf(before)) bool {
    if (before.count() != after.count()) return false;
    var entries = before.iterator();
    while (entries.next()) |entry| {
        const actual = after.get(entry.key_ptr.*) orelse return false;
        if (!constTransactionValueEqual(entry.value_ptr.*, actual)) return false;
    }
    // Also inspect physical entries: a shallow-copy writer can mutate hash
    // metadata while leaving the source header's count unchanged.
    var actual_count: usize = 0;
    var actual_entries = after.iterator();
    while (actual_entries.next() != null) actual_count += 1;
    return actual_count == before.count();
}

const WholeConstOperationObservation = struct {
    changed: bool,
    failed: bool,
    induced_oom: bool,
    unchanged_on_failure: bool,
    source_live_sid: u32,
    output_live_sid: ?u32,
    source_owner: module_mod.SemanticOwnerToken,
    output_owner: module_mod.SemanticOwnerToken,
    source_dead_owner: u32,
    dead_owner_retired: bool,
    provider_unknown: bool,
};

/// The full production driver owns the edit, not a hand-mutated AST followed
/// by a direct resync call. Its provider and consumer are real graph modules.
fn observeWholeConstOperation(fail_index: ?usize) !WholeConstOperationObservation {
    return observeWholeConstOperationAllocators(fail_index, .tree_heap);
}

const WholeConstFailureAllocator = enum { tree_heap, persistent_arena, linker_query };

fn observeWholeConstOperationAllocators(fail_index: ?usize, kind: WholeConstFailureAllocator) !WholeConstOperationObservation {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try @import("../test_helpers.zig").writeFile(tmp.dir, "provider.mjs", "export const seed=0;");
    try @import("../test_helpers.zig").writeFile(tmp.dir, "entry.mjs", "import{seed}from'./provider.mjs';if(seed){function dead(argument){return argument}console.log(dead(1))}export const live=seed+7;console.log(live);");
    const entry = try @import("../test_helpers.zig").absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    graph.transform_options_base.minify_syntax = true;
    try graph.build(std.testing.io, &.{entry});
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    const index = graph.path_to_module.get(entry) orelse return error.MissingWholeConstConsumer;
    const module = graph.moduleAtMut(index) orelse return error.MissingWholeConstConsumer;
    var shaker = try TreeShaker.init(a, &graph, &linker);
    defer shaker.deinit();
    const exported = module.findExportBinding("live") orelse return error.MissingWholeConstExport;
    const binding = exported.local_symbol_node orelse return error.MissingWholeConstBinding;
    const source_owner = module.semantic.?.captureOwnerToken();
    const original = try a.dupe(u8, std.mem.asBytes(module));
    defer a.free(original);
    const before_ast = module.ast orelse return error.MissingAst;
    const before_semantic = module.semantic orelse return error.MissingSemantic;
    const source_sid = before_semantic.symbol_ids[@backingInt(binding)] orelse return error.MissingWholeConstIdentity;
    var dead_owner: ?u32 = null;
    const source_reachable = try ast_walk.collectReachableNodeIndices(a, &before_ast);
    defer a.free(source_reachable);
    for (source_reachable) |raw| {
        const node = before_ast.nodes.items[raw];
        if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .arrow_function_expression) continue;
        if (dead_owner != null) return error.AmbiguousWholeConstFunction;
        const actual_scope = before_semantic.scope_owner_map.get(raw) orelse return error.MissingWholeConstFunctionOwner;
        if (actual_scope >= before_semantic.scopes.len or before_semantic.scopes[actual_scope].kind != .function) return error.MissingWholeConstFunctionOwner;
        dead_owner = @intCast(raw);
    }
    const source_dead_owner = dead_owner orelse return error.MissingWholeConstFunctionOwner;
    const nodes = try a.dupe(u8, std.mem.sliceAsBytes(before_ast.nodes.items));
    defer a.free(nodes);
    const extras = try a.dupe(u8, std.mem.sliceAsBytes(before_ast.extra_data.items));
    defer a.free(extras);
    const strings = try a.dupe(u8, before_ast.string_table.items);
    defer a.free(strings);
    const symbols = try a.dupe(u8, std.mem.sliceAsBytes(before_semantic.symbols.items));
    defer a.free(symbols);
    const ids = try a.dupe(u8, std.mem.sliceAsBytes(before_semantic.symbol_ids));
    defer a.free(ids);
    const references = try a.dupe(u8, std.mem.sliceAsBytes(before_semantic.references));
    defer a.free(references);
    const imports = try a.dupe(u8, std.mem.sliceAsBytes(module.import_bindings));
    defer a.free(imports);
    const exports = try a.dupe(u8, std.mem.sliceAsBytes(module.export_bindings));
    defer a.free(exports);
    const scope_bytes = try a.dupe(u8, std.mem.sliceAsBytes(before_semantic.scopes));
    defer a.free(scope_bytes);
    var owners_before = try before_semantic.scope_owner_map.clone(a);
    defer owners_before.deinit(a);
    var expressions_before = try before_semantic.node_scope_provenance.clone(a);
    defer expressions_before.deinit(a);
    var class_self_before = try before_semantic.class_self_symbol_map.clone(a);
    defer class_self_before.deinit(a);
    var helpers_before = try before_semantic.helper_scope_map.clone(a);
    defer helpers_before.deinit(a);
    var numbers_before = try before_semantic.numeric_const_texts.clone(a);
    defer numbers_before.deinit(a);
    var retirements_before = try before_semantic.source_owned_retirements.clone(a);
    defer retirements_before.deinit(a);
    var namespace_members_before = try before_semantic.namespace_member_owners.clone(a);
    defer namespace_members_before.deinit(a);
    var namespace_declarations_before = try before_semantic.namespace_declaration_owners.clone(a);
    defer namespace_declarations_before.deinit(a);
    var unresolved_before = try before_semantic.unresolved_references.clone(a);
    defer unresolved_before.deinit(a);
    var scope_maps_before: std.ArrayList(std.StringHashMapUnmanaged(usize)) = .empty;
    defer {
        for (scope_maps_before.items) |*map| map.deinit(a);
        scope_maps_before.deinit(a);
    }
    try scope_maps_before.ensureTotalCapacity(a, before_semantic.scope_maps.len);
    for (before_semantic.scope_maps) |map| scope_maps_before.appendAssumeCapacity(try map.clone(a));
    const record_bytes = try a.dupe(u8, std.mem.sliceAsBytes(module.import_records));
    defer a.free(record_bytes);
    const cache_delta_bytes = try a.dupe(u8, if (module.transform_cache) |cache_data| std.mem.sliceAsBytes(cache_data.ref_deltas) else &.{});
    defer a.free(cache_delta_bytes);
    const scratch_before = shaker.materialize_scratch;
    const mutated_before = shaker.ast_mutated_after_link;
    var failing = std.testing.FailingAllocator.init(if (kind == .persistent_arena) module.parse_arena.?.allocator() else a, .{ .fail_index = fail_index orelse std.math.maxInt(usize) });
    if (kind == .tree_heap) shaker.allocator = failing.allocator();
    if (kind == .linker_query) linker.allocator = failing.allocator();
    defer shaker.allocator = a;
    defer linker.allocator = a;
    var failed = false;
    const operation = if (kind == .persistent_arena)
        prepareAndPublishConstFactsForIndex(&shaker, index.toU32(), .all, prepassProfile(), failing.allocator())
    else
        materializeCrossModuleConstFactsForIndex(&shaker, index.toU32(), .all, prepassProfile());
    const changed = operation catch blk: {
        failed = true;
        break :blk false;
    };
    // A completed export-query memo may grow and provider collection may keep
    // its existing conservative-eviction policy. Neither is a failed Module
    // publication merely because an optional allocation was recovered.
    const failure = failed or !changed;
    const after_ast = module.ast orelse return error.MissingAst;
    const after_semantic = module.semantic orelse return error.MissingSemantic;
    const output_sid = if (@backingInt(binding) < after_semantic.symbol_ids.len) after_semantic.symbol_ids[@backingInt(binding)] else null;
    var scope_maps_same = after_semantic.scope_maps.len == scope_maps_before.items.len;
    if (scope_maps_same) for (scope_maps_before.items, after_semantic.scope_maps) |before_map, after_map| {
        if (!constTransactionMapEqual(before_map, after_map)) scope_maps_same = false;
    };
    const maps_same = scope_maps_same and
        constTransactionMapEqual(owners_before, after_semantic.scope_owner_map) and
        constTransactionMapEqual(expressions_before, after_semantic.node_scope_provenance) and
        constTransactionMapEqual(class_self_before, after_semantic.class_self_symbol_map) and
        constTransactionMapEqual(helpers_before, after_semantic.helper_scope_map) and
        constTransactionMapEqual(numbers_before, after_semantic.numeric_const_texts) and
        constTransactionMapEqual(retirements_before, after_semantic.source_owned_retirements) and
        constTransactionMapEqual(namespace_members_before, after_semantic.namespace_member_owners) and
        constTransactionMapEqual(namespace_declarations_before, after_semantic.namespace_declaration_owners) and
        constTransactionMapEqual(unresolved_before, after_semantic.unresolved_references);
    const same = maps_same and std.mem.eql(u8, original, std.mem.asBytes(module)) and
        std.mem.eql(u8, nodes, std.mem.sliceAsBytes(after_ast.nodes.items)) and
        std.mem.eql(u8, extras, std.mem.sliceAsBytes(after_ast.extra_data.items)) and
        std.mem.eql(u8, strings, after_ast.string_table.items) and
        std.mem.eql(u8, symbols, std.mem.sliceAsBytes(after_semantic.symbols.items)) and
        std.mem.eql(u8, ids, std.mem.sliceAsBytes(after_semantic.symbol_ids)) and
        std.mem.eql(u8, references, std.mem.sliceAsBytes(after_semantic.references)) and
        std.mem.eql(u8, imports, std.mem.sliceAsBytes(module.import_bindings)) and
        std.mem.eql(u8, exports, std.mem.sliceAsBytes(module.export_bindings)) and
        std.mem.eql(u8, record_bytes, std.mem.sliceAsBytes(module.import_records)) and
        std.mem.eql(u8, scope_bytes, std.mem.sliceAsBytes(after_semantic.scopes)) and
        std.mem.eql(u8, cache_delta_bytes, if (module.transform_cache) |cache_data| std.mem.sliceAsBytes(cache_data.ref_deltas) else &.{}) and
        std.meta.eql(scratch_before, shaker.materialize_scratch) and
        mutated_before == shaker.ast_mutated_after_link;
    return .{ .changed = changed, .failed = failure, .induced_oom = failing.has_induced_failure, .unchanged_on_failure = !failure or same, .source_live_sid = source_sid, .output_live_sid = output_sid, .source_owner = source_owner, .output_owner = after_semantic.owner_token, .source_dead_owner = source_dead_owner, .dead_owner_retired = !after_semantic.scope_owner_map.contains(source_dead_owner), .provider_unknown = module.const_baked and module.const_providers.len == 0 };
}

test "const whole transaction keeps the actual graph owner and surviving export identity" {
    const observed = try observeWholeConstOperation(null);
    try std.testing.expect(observed.changed);
    try std.testing.expect(!observed.failed);
    try std.testing.expectEqual(@as(?u32, observed.source_live_sid), observed.output_live_sid);
    try std.testing.expectEqual(observed.source_owner, observed.output_owner);
    try std.testing.expect(observed.dead_owner_retired);
}

test "const whole transaction rejected or OOM preparation leaves original publication unchanged" {
    var actual_failures: usize = 0;
    var violations: usize = 0;
    for (0..64) |fail_index| {
        const observed = try observeWholeConstOperation(fail_index);
        if (observed.failed) {
            actual_failures += 1;
            if (!observed.unchanged_on_failure) {
                violations += 1;
                std.debug.print("CONST_WHOLE_PARTIAL_FAILURE offset={d} induced={} sourceSID={d} outputSID={any}\n", .{ fail_index, observed.induced_oom, observed.source_live_sid, observed.output_live_sid });
            }
        }
    }
    try std.testing.expect(actual_failures > 0);
    try std.testing.expectEqual(@as(usize, 0), violations);
}

fn observeRepeatedConstProviderPaths(star_second_provider: bool, old_unknown: bool, dead_function_first: bool) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "first.mjs", "export const first=7;");
    try helpers.writeFile(tmp.dir, "second.mjs", "export const second=4+4;");
    if (star_second_provider) try helpers.writeFile(tmp.dir, "barrel.mjs", "export*from'./second.mjs';");
    const source_base = if (star_second_provider)
        "import{first}from'./first.mjs';import{second}from'./barrel.mjs';export const left=first;export const right=second;console.log(left,right);"
    else
        "import{first}from'./first.mjs';import{second}from'./second.mjs';export const left=first;export const right=second;console.log(left,right);";
    const decorated_source = if (dead_function_first)
        try std.fmt.allocPrint(a, "{s}if(first-7){{function removed(arg){{return arg}}console.log(removed(1));}}", .{source_base})
    else
        null;
    defer if (decorated_source) |owned| a.free(owned);
    try helpers.writeFile(tmp.dir, "entry.mjs", decorated_source orelse source_base);
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const second_path = try helpers.absPath(&tmp, "second.mjs");
    defer a.free(second_path);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    graph.transform_options_base.minify_syntax = false;
    try graph.build(std.testing.io, &.{entry});
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    linker.populateImportSymbols();
    var shaker = try TreeShaker.init(a, &graph, &linker);
    defer shaker.deinit();
    const index = graph.path_to_module.get(entry) orelse return error.MissingRepeatedConsumer;
    const module = graph.moduleAtMut(index) orelse return error.MissingRepeatedConsumer;
    const second_index = graph.path_to_module.get(second_path) orelse return error.MissingRepeatedProvider;
    const second = graph.moduleAtMut(second_index) orelse return error.MissingRepeatedProvider;
    const source_owner = module.semantic.?.captureOwnerToken();
    var known_dead_owner: ?u32 = null;
    if (dead_function_first) {
        const source_reachable = try ast_walk.collectReachableNodeIndices(a, &module.ast.?);
        defer a.free(source_reachable);
        for (source_reachable) |raw| {
            const node = module.ast.?.nodes.items[raw];
            if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .arrow_function_expression) continue;
            if (known_dead_owner != null or !module.semantic.?.scope_owner_map.contains(raw)) return error.InvalidRepeatedFunctionOwner;
            known_dead_owner = raw;
        }
        if (known_dead_owner == null) return error.MissingRepeatedFunctionOwner;
    }
    const numeric_profile: ConstMaterializeProfile = .{ .policy = .numeric_post_pass };
    try std.testing.expect(try materializeCrossModuleConstFactsForIndex(&shaker, index.toU32(), .numeric, numeric_profile));
    try std.testing.expect(module.const_baked);
    try std.testing.expectEqual(@as(usize, 1), module.const_providers.len);
    try std.testing.expectEqual(source_owner, module.semantic.?.owner_token);
    if (known_dead_owner) |owner| try std.testing.expect(!module.semantic.?.scope_owner_map.contains(owner));
    if (old_unknown) module.const_providers = &.{};
    // The second fact is produced from its actual exported initializer by the
    // existing numeric fold, not by assigning a guessed SID/value in the test.
    try std.testing.expect(try foldNumericExportSeeds(&shaker, second, &second.ast.?));
    try std.testing.expect(try materializeCrossModuleConstFactsForIndex(&shaker, index.toU32(), .numeric, numeric_profile));
    try std.testing.expect(module.const_baked);
    try std.testing.expectEqual(source_owner, module.semantic.?.owner_token);
    if (known_dead_owner) |owner| try std.testing.expect(!module.semantic.?.scope_owner_map.contains(owner));
    if (star_second_provider or old_unknown) {
        // The collector cannot prove a complete star forwarding chain. A new
        // bake must not leave the old first-provider-only list looking complete.
        try std.testing.expectEqual(@as(usize, 0), module.const_providers.len);
    } else {
        try std.testing.expectEqual(@as(usize, 2), module.const_providers.len);
        var saw_first = false;
        var saw_second = false;
        for (module.const_providers) |path| {
            if (std.mem.endsWith(u8, path, "/first.mjs")) saw_first = true;
            if (std.mem.eql(u8, path, second_path)) saw_second = true;
        }
        try std.testing.expect(saw_first and saw_second);
    }
}

test "const whole transaction repeated complete bakes preserve both actual provider paths" {
    try observeRepeatedConstProviderPaths(false, false, false);
}

test "const whole transaction repeated incomplete bake preserves conservative unknown providers" {
    try observeRepeatedConstProviderPaths(true, false, false);
}

test "const whole transaction complete rebake cannot heal prior unknown providers" {
    try observeRepeatedConstProviderPaths(false, true, false);
}

test "const whole transaction provider collection OOM publishes only conservative unknown" {
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..20) |offset| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "provider-oom.mjs");
        module.const_baked = true;
        module.const_providers = &.{"first.mjs"};
        var collector: Linker.ConstProviderCollector = .{};
        try collector.paths.put(a, "second.mjs", {});
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = offset });
        const prepared = prepareConstProviderPathsWithAllocator(failing.allocator(), &module, &collector);
        // This helper prepares dependency metadata only. Even its successful
        // conservative-unknown result has not changed the original module.
        try std.testing.expectEqual(@as(usize, 1), module.const_providers.len);
        try std.testing.expectEqualStrings("first.mjs", module.const_providers[0]);
        if (failing.has_induced_failure) {
            failures += 1;
            try std.testing.expectEqual(@as(usize, 0), prepared.len);
        } else {
            successes += 1;
            try std.testing.expectEqual(@as(usize, 2), prepared.len);
            try std.testing.expectEqualStrings("first.mjs", prepared[0]);
            try std.testing.expectEqualStrings("second.mjs", prepared[1]);
        }
    }
    try std.testing.expect(failures > 0 and successes > 0);
}

test "const whole transaction persistent arena OOM leaves original graph or publishes a complete candidate" {
    var rejected: usize = 0;
    var recovered: usize = 0;
    var complete = false;
    for (0..1024) |index| {
        const observed = try observeWholeConstOperationAllocators(index, .persistent_arena);
        if (observed.failed) {
            rejected += 1;
            try std.testing.expect(observed.unchanged_on_failure);
        } else {
            try std.testing.expect(observed.changed);
            try std.testing.expectEqual(observed.source_live_sid, observed.output_live_sid.?);
            try std.testing.expectEqual(observed.source_owner, observed.output_owner);
            try std.testing.expect(observed.dead_owner_retired);
            if (observed.induced_oom) recovered += 1;
        }
        if (!observed.induced_oom) {
            try std.testing.expect(observed.changed);
            complete = true;
            break;
        }
    }
    try std.testing.expect(complete and rejected > 0);
    std.debug.print("CONST_WHOLE_PERSISTENT_OOM rejected={d} recovered={d} complete={}\n", .{ rejected, recovered, complete });
}

test "const whole transaction repeated bake preserves source retirement state and prior providers" {
    try observeRepeatedConstProviderPaths(false, false, true);
}

test "const whole transaction linker query OOM separates rollback from conservative provider success" {
    var rejected: usize = 0;
    var recovered: usize = 0;
    var recovered_unknown: usize = 0;
    var complete = false;
    for (0..128) |index| {
        const observed = try observeWholeConstOperationAllocators(index, .linker_query);
        if (observed.failed) {
            rejected += 1;
            try std.testing.expect(observed.unchanged_on_failure);
        } else {
            try std.testing.expect(observed.changed and observed.dead_owner_retired);
            try std.testing.expectEqual(observed.source_live_sid, observed.output_live_sid.?);
            try std.testing.expectEqual(observed.source_owner, observed.output_owner);
            if (observed.induced_oom) {
                recovered += 1;
                if (observed.provider_unknown) recovered_unknown += 1;
            }
        }
        if (!observed.induced_oom) {
            try std.testing.expect(observed.changed);
            complete = true;
            break;
        }
    }
    try std.testing.expect(complete and rejected > 0 and recovered_unknown > 0);
    std.debug.print("CONST_WHOLE_LINKER_OOM rejected={d} recovered={d} recoveredUnknown={d} complete={}\n", .{ rejected, recovered, recovered_unknown, complete });
}

const ConstAuthorityPoison = enum { foreign_linker, paired_import_anchor, paired_same_property };

fn expectConstWholeAuthorityRejected(poison: ConstAuthorityPoison) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "provider.mjs", "export const seed=0;export const other=7;");
    try helpers.writeFile(tmp.dir, "entry.mjs", if (poison == .paired_same_property)
        "import{seed,seed as other}from'./provider.mjs';export const live=seed+other;console.log(live);"
    else
        "import{seed,other}from'./provider.mjs';export const live=seed+other;console.log(live);");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    graph.transform_options_base.minify_syntax = true;
    try graph.build(std.testing.io, &.{entry});
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    const index = graph.path_to_module.get(entry) orelse return error.MissingWholeConstConsumer;
    const module = graph.moduleAtMut(index) orelse return error.MissingWholeConstConsumer;
    var foreign_cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer foreign_cache.deinit();
    var foreign = @import("../graph.zig").ModuleGraph.init(a, &foreign_cache);
    defer foreign.deinit();
    foreign.transform_options_base.minify_syntax = true;
    try foreign.build(std.testing.io, &.{entry});
    var foreign_linker = Linker.init(a, &foreign, .esm);
    defer foreign_linker.deinit();
    try foreign_linker.link();
    if (poison == .paired_import_anchor or poison == .paired_same_property) {
        try std.testing.expectEqual(@as(usize, 2), module.import_bindings.len);
        const other = module.import_bindings[1];
        module.import_bindings[0].local_symbol = other.local_symbol;
        module.import_bindings[0].local_symbol_node = other.local_symbol_node;
        // The carrier still names the first actual specifier. A matching SID
        // and node from its sibling must not authorize that source relation.
    }
    const before = try a.dupe(u8, std.mem.asBytes(module));
    defer a.free(before);
    var shaker = try TreeShaker.init(a, &graph, if (poison == .foreign_linker) &foreign_linker else &linker);
    defer shaker.deinit();
    const changed = try materializeCrossModuleConstFactsForIndex(&shaker, index.toU32(), .all, prepassProfile());
    try std.testing.expect(!changed);
    try std.testing.expectEqualSlices(u8, before, std.mem.asBytes(module));
}

test "const whole transaction rejects a foreign linker with matching module indices" {
    try expectConstWholeAuthorityRejected(.foreign_linker);
}

test "const whole transaction rejects a paired sibling import node and SID" {
    try expectConstWholeAuthorityRejected(.paired_import_anchor);
}

test "const whole transaction fact query releases a partially grown import map on OOM" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var provider: std.ArrayList(u8) = .empty;
    defer provider.deinit(a);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a, "import{");
    for (0..20) |i| {
        const declaration = try std.fmt.allocPrint(a, "export const value{d}={d};", .{ i, i });
        defer a.free(declaration);
        try provider.appendSlice(a, declaration);
        const specifier = try std.fmt.allocPrint(a, "{s}value{d}", .{ if (i == 0) "" else ",", i });
        defer a.free(specifier);
        try input.appendSlice(a, specifier);
    }
    try input.appendSlice(a, "}from'./provider.mjs';console.log(");
    for (0..20) |i| {
        const use = try std.fmt.allocPrint(a, "{s}value{d}", .{ if (i == 0) "" else "+", i });
        defer a.free(use);
        try input.appendSlice(a, use);
    }
    try input.appendSlice(a, ");");
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "provider.mjs", provider.items);
    try helpers.writeFile(tmp.dir, "entry.mjs", input.items);
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    linker.populateImportSymbols();
    const index = graph.path_to_module.get(entry) orelse return error.MissingWholeConstConsumer;
    const module = graph.moduleAtMut(index) orelse return error.MissingWholeConstConsumer;
    // Complete resolver-query memoization before measuring the newly allocated
    // result map. Persistent valid memo entries are not transaction damage.
    var warm = try linker.buildCrossModuleConstValues(module, module.semantic.?);
    try std.testing.expectEqual(@as(usize, 20), warm.count());
    warm.deinit(a);
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..16) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = offset });
        linker.allocator = failing.allocator();
        defer linker.allocator = a;
        if (linker.buildCrossModuleConstValues(module, module.semantic.?)) |result| {
            var owned = result;
            try std.testing.expectEqual(@as(usize, 20), owned.count());
            owned.deinit(failing.allocator());
            successes += 1;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
        }
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    try std.testing.expect(failures > 0 and successes > 0);
}

test "const whole transaction rejects paired aliases of the same imported property" {
    try expectConstWholeAuthorityRejected(.paired_same_property);
}

test "const whole transaction restored-source receipt survives refusal and retires only on COW publication" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const Store = @import("../disk_module_store.zig").DiskModuleStore;
    const Graph = @import("../graph.zig").ModuleGraph;
    const Cache = @import("../resolve_cache.zig").ResolveCache;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "export const seed=7;");
    try helpers.writeFile(tmp.dir, "entry.mjs", "import{seed}from'./provider.mjs';export const live=seed;console.log(live);");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const cache_root = try helpers.absPath(&tmp, "cache");
    defer a.free(cache_root);
    {
        var store = try Store.init(a, cache_root);
        defer store.deinit();
        var cache = Cache.init(a, .{});
        defer cache.deinit();
        var graph = Graph.init(a, &cache);
        defer graph.deinit();
        graph.disk_cache = &store;
        graph.disk_options_hash = 0x5c0;
        graph.disk_compiler_build_id = 0x4819;
        graph.disk_load_enabled = true;
        try graph.build(std.testing.io, &.{entry});
        try std.testing.expectEqual(@as(usize, 0), graph.disk_load_hits.load(.monotonic));
    }
    var store = try Store.init(a, cache_root);
    defer store.deinit();
    var cache = Cache.init(a, .{});
    defer cache.deinit();
    var graph = Graph.init(a, &cache);
    defer graph.deinit();
    graph.disk_cache = &store;
    graph.disk_options_hash = 0x5c0;
    graph.disk_compiler_build_id = 0x4819;
    graph.disk_load_enabled = true;
    try graph.build(std.testing.io, &.{entry});
    try std.testing.expect(graph.disk_load_hits.load(.monotonic) > 0);
    const index = graph.path_to_module.get(entry) orelse return error.MissingWholeConstConsumer;
    const module = graph.moduleAtMut(index) orelse return error.MissingWholeConstConsumer;
    const receipt = module.self_namespace_source_receipt orelse return error.MissingActualDiskSourceReceipt;
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    var shaker = try TreeShaker.init(a, &graph, &linker);
    defer shaker.deinit();
    // Snapshot after the normal Linker producer: failure must not allocate a
    // source owner or replace a restored physical-source receipt.
    const ready = try a.dupe(u8, std.mem.asBytes(module));
    defer a.free(ready);
    var failing = std.testing.FailingAllocator.init(module.parse_arena.?.allocator(), .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, prepareAndPublishConstFactsForIndex(&shaker, index.toU32(), .numeric, .{ .policy = .numeric_post_pass }, failing.allocator()));
    try std.testing.expectEqualSlices(u8, ready, std.mem.asBytes(module));
    try std.testing.expect(module.self_namespace_source_receipt == receipt);
    const old_nodes = module.ast.?.nodes.items.ptr;
    try std.testing.expect(try materializeCrossModuleConstFactsForIndex(&shaker, index.toU32(), .numeric, .{ .policy = .numeric_post_pass }));
    try std.testing.expect(module.ast.?.nodes.items.ptr != old_nodes);
    try std.testing.expect(module.self_namespace_source_receipt == null);
}

test "const whole transaction actual disk namespace receipt preserves registered owner authority" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const Store = @import("../disk_module_store.zig").DiskModuleStore;
    const Graph = @import("../graph.zig").ModuleGraph;
    const Cache = @import("../resolve_cache.zig").ResolveCache;
    const lowering = @import("../self_namespace_ast.zig");
    const options: lowering.Options = .{ .format = .esm, .scope_hoist = true, .minify_syntax = false };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "self.mjs", "export const value=7;console.log(Reflect.get(ns,'value'));import*as ns from'./self.mjs';");
    const entry = try helpers.absPath(&tmp, "self.mjs");
    defer a.free(entry);
    const cache_root = try helpers.absPath(&tmp, "cache");
    defer a.free(cache_root);
    var store = try Store.init(a, cache_root);
    defer store.deinit();
    var cache = Cache.init(a, .{});
    defer cache.deinit();
    var cold = Graph.init(a, &cache);
    defer cold.deinit();
    cold.disk_cache = &store;
    cold.disk_options_hash = 17;
    cold.disk_compiler_build_id = 31;
    cold.disk_load_enabled = true;
    try cold.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 0), cold.disk_load_hits.load(.monotonic));
    try lowering.lower(&cold, options);
    try std.testing.expectEqual(@as(usize, 1), cold.self_namespace_holders.count());
    var warm = Graph.init(a, &cache);
    defer warm.deinit();
    warm.disk_cache = &store;
    warm.disk_options_hash = 17;
    warm.disk_compiler_build_id = 31;
    warm.disk_load_enabled = true;
    try warm.build(std.testing.io, &.{entry});
    try std.testing.expectEqual(@as(usize, 1), warm.disk_load_hits.load(.monotonic));
    const index = warm.path_to_module.get(entry) orelse return error.MissingWholeConstConsumer;
    const module = warm.moduleAtMut(index) orelse return error.MissingWholeConstConsumer;
    const receipt = module.self_namespace_source_receipt orelse return error.MissingActualDiskSourceReceipt;
    try std.testing.expect(module.semantic.?.owner_token != .unassigned);
    std.debug.print("CONST_DISK_OWNER before receipt={any} installed={any} warmHit=1 coldPlan=1\n", .{ receipt.owner, module.semantic.?.owner_token });
    try lowering.lower(&warm, options);
    std.debug.print("CONST_DISK_OWNER actualWarmPlans={d}\n", .{warm.self_namespace_holders.count()});
    try std.testing.expectEqual(@as(usize, 1), warm.self_namespace_holders.count());
    try lowering.validate(&warm, module);
}
