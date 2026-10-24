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

/// Const materialization only replaces leaf identifiers with literals, so
/// import/export statement indexing and materialize scratch remain valid.
fn markConstMaterializedAndResync(self: *TreeShaker, m: *Module) void {
    std.debug.assert(m.parse_arena != null);
    // L.5a: code_splitting 은 carry-over apply 미실행 → capture skip (store dangling 방지, tree_shaker 와 동일).
    const rt: ?*const @import("../symbol.zig").RenameTable = if (self.graph.code_splitting) null else &self.linker.rename_table;
    self.graph.resyncModuleMetadataAfterConstMaterialization(m, m.parse_arena.?.allocator(), rt) catch {
        m.prebuilt_stmt_info = null;
    };
    // PR #3738: AST mutation 후 cached namespace_access_index 는 stale (node_idx 매핑 + text key
    // 모두 invalidate 가능). linker.refreshAfterAstMutation → populateNamespaceAccesses 가 fallback
    // build path 로 가도록 cache 무효화. parse_arena 가 backing 소유 — null 만으로 충분 (memory leak
    // 없음, arena 통째 free).
    m.namespace_access_index = null;
    self.ast_mutated_after_link = true;
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
    refresh_module_metadata: bool,
) bool {
    std.debug.assert(m.parse_arena != null);
    const retained = self.graph.resyncModuleMetadataAfterConstMaterializationRetainingMinifiedGraph(
        m,
        m.parse_arena.?.allocator(),
        materialized_nodes,
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
    const sem = if (m.semantic) |*value| value else return;
    const allocator = if (m.parse_arena) |arena| arena.allocator() else return;
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
) !void {
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

        const retained = if (m.semantic != null and materialized.tracked_nodes_complete) blk: {
            if (skip_minify) break :blk markConstMaterializedRetainingGraph(self, m, materialized_nodes);
            break :blk markConstMaterializedRetainingMinifiedGraph(
                self,
                m,
                materialized_nodes,
                !const_profile.policy.stableImportExportSyntax(),
            );
        } else false;
        if (!retained) {
            if (const_profile.policy.stableImportExportSyntax()) {
                markConstMaterializedAndResync(self, m);
            } else {
                self.markAstMutatedAndResync(m);
            }
        }
    }
    try refreshFoldedNumericExportFacts(self, m, ast);
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
    // (#4557 B-precise) provider 경로 수집기. GPA(self.allocator)로 만들고 함수 끝 deinit.
    // buildCrossModuleConstValuesProfiled 가 체인 전체를 채운 뒤, bake 확정 시 parse_arena 로 dupe 해
    // module 에 기록. collector.incomplete(다단 체인 미추적)면 crude-b 폴백.
    var collector: Linker.ConstProviderCollector = .{};
    defer collector.paths.deinit(self.allocator);
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
    var eligible_reference_nodes = try materializableReferenceNodes(self.allocator, ast, sem);
    defer eligible_reference_nodes.deinit();
    var materialized_nodes: std.ArrayList(NodeIndex) = .empty;
    defer materialized_nodes.deinit(self.allocator);
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
            &eligible_reference_nodes,
            &materialized_nodes,
        );
    };
    const_values.deinit(self.allocator);
    if (!materialized.changed) return false;

    // (#4544) 이 모듈 AST 에 cross-module const 를 bake 함 → module_store 캐시에서 제외되도록 표시.
    // baked 값은 provider const 에 의존하므로 소비자 mtime 캐시로 재사용하면 stale.
    m.const_baked = true;

    // (#4557 B-precise, [1][3]) 이 bake 가 의존하는 provider 경로(diskPath, 체인 전체)를 parse_arena 로
    // dupe 해 module 에 기록. arena 소유(arena.deinit 일괄 해제 — #1287, 수동 free 금지). warm
    // invalidation 이 이 집합으로 provider 변경 시에만 baked 소비자를 evict(전이 fixpoint).
    // **crude-b 폴백**: collector.incomplete(다단 re-export 체인 미추적, [1]) 또는 dupe OOM 또는
    // parse_arena 없음(virtual)이면 const_providers 를 **빈 채로 둔다** → transferModulesToStore 가
    // `const_baked && const_providers.len==0` 게이트로 crude-b(무조건 evict, 캐시 안 함)로 폴백 →
    // staleness 원천 차단([3]). "빈=conservative evict" 는 [3] 게이트가 실제로 보장한다.
    if (!collector.incomplete) {
        if (m.parse_arena) |arena| {
            const aa = arena.allocator();
            const n = collector.paths.count();
            if (n > 0) {
                if (aa.alloc([]const u8, n)) |slice| {
                    var it = collector.paths.keyIterator();
                    var i: usize = 0;
                    var ok = true;
                    while (it.next()) |k| : (i += 1) {
                        slice[i] = aa.dupe(u8, k.*) catch {
                            ok = false; // dupe OOM → 빈 채로 두어 crude-b 폴백.
                            break;
                        };
                    }
                    if (ok) m.const_providers = slice;
                } else |_| {}
            }
        }
    }

    const skip_minify = const_profile.policy.skipMinifyIfSafe() and !materialized.needs_minify;
    try minifyAndResyncModule(
        self,
        m,
        sem,
        ast,
        const_profile,
        materialized,
        materialized_nodes.items,
        skip_minify,
    );
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
    const source = if (skip_minify)
        "const value=7; if(false) console.log(value); console.log(value); function read(){return value;}"
    else
        "export const value=7; console.log(value + 2); export function read(input){return value + input;}";

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

    var value_symbol: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, index| {
        if (symbol.kind == .variable_const and std.mem.eql(u8, parser.ast.getText(symbol.name), "value")) {
            value_symbol = @intCast(index);
            break;
        }
    }
    const value_id = value_symbol orelse return error.MissingValueSymbol;

    // This field is graph-owned naming metadata. A full analyzer rebuild drops
    // it, so preserving it proves this call took the same-graph path.
    analyzer.symbols.items[value_id].output_name_hint = "retained-graph-marker";
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
            .none, .stale_sidecar, .incomplete_tracking => {},
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

    try minifyAndResyncModule(
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
    if (mutation != .none) {
        try std.testing.expectEqualStrings("", semantic.symbols.items[value_id].output_name_hint);
        try std.testing.expect(module.prebuilt_stmt_info != null);
        try std.testing.expect(shaker.ast_mutated_after_link);
        return;
    }
    try std.testing.expectEqualStrings("retained-graph-marker", semantic.symbols.items[value_id].output_name_hint);
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
    try std.testing.expect(module.prebuilt_stmt_info != null);
    try std.testing.expect(shaker.ast_mutated_after_link);
}

test "numeric post-pass retains graph when prepass ref deltas exist" {
    try expectConstMaterializeGraphHandoff(true, .none, .numeric_post_pass);
}

test "numeric post-pass retains exact graph through syntax folding" {
    try expectConstMaterializeGraphHandoff(false, .none, .numeric_post_pass);
}

test "numeric post-pass falls back when minification strands a graph sidecar" {
    try expectConstMaterializeGraphHandoff(false, .stale_sidecar, .numeric_post_pass);
}

test "numeric post-pass rejects malformed materialized read handoffs" {
    inline for (std.meta.tags(MinifiedConstInputMutation)) |mutation| {
        switch (mutation) {
            .none, .stale_sidecar => {},
            else => try expectConstMaterializeGraphHandoff(false, mutation, .numeric_post_pass),
        }
    }
}

test "full const pre-pass retains the exact graph when syntax minification preserves it" {
    try expectConstMaterializeGraphHandoff(false, .none, .pre_pass);
}

test "full const pre-pass rejects malformed materialized read handoffs" {
    inline for (std.meta.tags(MinifiedConstInputMutation)) |mutation| {
        switch (mutation) {
            .none => {},
            else => try expectConstMaterializeGraphHandoff(false, mutation, .pre_pass),
        }
    }
}
