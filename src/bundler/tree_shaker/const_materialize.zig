//! Cross-module constant materialization used by tree-shaking.
//!
//! This module owns the pre-shake const propagation and the post-shake numeric
//! worklist. Keeping it separate leaves `tree_shaker.zig` focused on graph
//! reachability and export/include fixpoint logic.

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
const ast_walk = @import("../../parser/ast_walk.zig");
const constant_facts = @import("../constant_facts.zig");
const ConstValue = @import("../../semantic/symbol.zig").ConstValue;
const profile = @import("../../profile.zig");
const TreeShaker = @import("../tree_shaker.zig").TreeShaker;

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
        const raw: u32 = @intFromEnum(idx);
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
        const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
        const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra + 2]);
        if (name_idx.isNone() or init_idx.isNone()) continue;
        const name_raw: u32 = @intFromEnum(name_idx);
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
        const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra]);
        const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra + 2]);
        if (name_idx.isNone() or init_idx.isNone()) continue;
        const name_raw: u32 = @intFromEnum(name_idx);
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

/// Const materialization only replaces leaf identifiers with literals, so
/// import/export statement indexing and materialize scratch remain valid.
fn markConstMaterializedAndResync(self: *TreeShaker, m: *Module) void {
    std.debug.assert(m.parse_arena != null);
    self.graph.resyncModuleMetadataAfterConstMaterialization(m, m.parse_arena.?.allocator(), &self.linker.rename_table) catch {
        m.prebuilt_stmt_info = null;
    };
    // PR #3738: AST mutation 후 cached namespace_access_index 는 stale (node_idx 매핑 + text key
    // 모두 invalidate 가능). linker.refreshAfterAstMutation → populateNamespaceAccesses 가 fallback
    // build path 로 가도록 cache 무효화. parse_arena 가 backing 소유 — null 만으로 충분 (memory leak
    // 없음, arena 통째 free).
    m.namespace_access_index = null;
    self.ast_mutated_after_link = true;
}

fn minifyAndResyncModule(
    self: *TreeShaker,
    m: *Module,
    sem: ModuleSemanticData,
    ast: *Ast,
    const_profile: ConstMaterializeProfile,
    skip_minify: bool,
) void {
    var scope = profile.beginMaybe(const_profile.minify_resync);
    defer scope.end();

    if (skip_minify) {
        var skip_scope = profile.beginMaybe(const_profile.minify_skip);
        defer skip_scope.end();
    } else {
        var minify_scope = profile.beginMaybe(const_profile.minify);
        defer minify_scope.end();

        const minify_mod = @import("../../transformer/minify.zig");
        const root = ast.transformed_root orelse NodeIndex.none;
        const ctx = minify_mod.MinifyCtx.fromSemantic(&m.semantic.?, sem.symbol_ids, self.graph.transform_options_base.minify_syntax);
        minify_mod.minify(ast, ctx, self.allocator, root);
    }

    {
        var resync_scope = profile.beginMaybe(const_profile.resync);
        defer resync_scope.end();

        if (const_profile.policy.stableImportExportSyntax()) {
            markConstMaterializedAndResync(self, m);
        } else {
            self.markAstMutatedAndResync(m);
        }
    }
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

fn materializeCrossModuleConstFactsForIndex(
    self: *TreeShaker,
    module_index: usize,
    filter: ConstMaterializeFilter,
    const_profile: ConstMaterializeProfile,
) !bool {
    const m = moduleAtMut(self, @intCast(module_index)) orelse return false;
    if (m.import_bindings.len == 0) return false;
    const sem = m.semantic orelse return false;
    const ast = &(m.ast orelse return false);
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
        break :blk try self.linker.buildCrossModuleConstValuesProfiled(m, sem, build_profile);
    };
    const should_materialize = blk: {
        var gate_scope = profile.beginMaybe(const_profile.candidate_gate);
        defer gate_scope.end();
        break :blk shouldMaterializeConstFacts(self, ast, sem, &const_values, filter);
    };
    if (!should_materialize) {
        const_values.deinit(self.allocator);
        return false;
    }

    if (self.materialize_scratch == null) {
        self.materialize_scratch = Scratch.init(self.allocator, self.graph.moduleCount()) catch null;
    }
    const scratch_ptr: ?*Scratch = if (self.materialize_scratch) |*s| s else null;
    const materialized = blk: {
        var materialize_scope = profile.beginMaybe(const_profile.materialize);
        defer materialize_scope.end();
        break :blk constant_facts.materializeWithScratchDetailed(
            self.allocator,
            ast,
            sem.symbol_ids,
            &const_values,
            scratch_ptr,
            module_index,
            const_profile.inner,
            const_profile.policy.skipMinifyIfSafe(),
        );
    };
    const_values.deinit(self.allocator);
    if (!materialized.changed) return false;

    const skip_minify = const_profile.policy.skipMinifyIfSafe() and !materialized.needs_minify;
    minifyAndResyncModule(self, m, sem, ast, const_profile, skip_minify);
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
        try enqueueNumericPostPassModule(self, queue, queued, @intCast(@intFromEnum(imp)), mod_count);
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
        const ii = @intFromEnum(imp);
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
