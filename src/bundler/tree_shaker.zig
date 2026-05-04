//! ZTS Bundler — Tree Shaker (Phase B2, 1단계)
//!
//! 미사용 export 제거: 모듈 그래프에서 실제로 import되는 export만 추적하고,
//! 사용되는 export가 없고 side_effects도 없는 모듈을 번들에서 제거한다.
//!
//! 설계:
//!   - 1단계: export 사용 추적 (모듈 수준)
//!   - 진입점 모듈의 모든 export → "사용됨"
//!   - import binding → 해당 export "사용됨" 마킹
//!   - side_effects=true인 모듈 → 항상 포함
//!   - 사용되는 export 없고 side_effects=false → 번들에서 제거
//!
//! 참고:
//!   - references/rolldown/crates/rolldown/src/stages/link_stage/tree_shaking/
//!   - references/esbuild/internal/linker/linker.go (markFileLiveForTreeShaking)

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const ModuleSemanticData = module_mod.ModuleSemanticData;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const ImportBinding = @import("binding_scanner.zig").ImportBinding;
const Linker = @import("linker.zig").Linker;
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const ast_walk = @import("../parser/ast_walk.zig");
const Kind = @import("../lexer/token.zig").Kind;
const purity = @import("purity.zig");
const stmt_info_mod = @import("stmt_info.zig");
const StmtInfos = stmt_info_mod.ModuleStmtInfos;
const constant_facts = @import("constant_facts.zig");
const ConstValue = @import("../semantic/symbol.zig").ConstValue;
const runtime_helper_modules = @import("../runtime_helper_modules.zig");
const profile = @import("../profile.zig");

/// `used_exports`의 all-exports-used sentinel. 모듈의 전체 export가 사용됨을 표시.
/// 일반 export 이름과 겹치지 않도록 의도적으로 JS 식별자 아닌 `"*"` 선택.
/// (export_bindings의 `exported_name == "*"`는 wildcard re-export로 의미가 다름 — 같은 문자열, 다른 공간)
pub const ALL_EXPORTS_SENTINEL: []const u8 = "*";

fn isImportDeclarationStmt(m: *const Module, infos: StmtInfos, stmt_idx: u32) bool {
    if (stmt_idx >= infos.stmts.len) return false;
    const ast = &(m.ast orelse return false);
    const ni: usize = infos.stmts[stmt_idx].node_idx;
    return ni < ast.nodes.items.len and ast.nodes.items[ni].tag == .import_declaration;
}

/// 모듈을 evaluation 의존으로 끌어와야 하는 부수효과가 있는지.
/// `.cjs` wrap 은 정적 분석 불가 — 항상 evaluation 의존. `.esm` wrap 은 _emit shape_
/// (lazy init / circular dep) 일 뿐 semantic side-effect 가 아니지만, 기존 RN/Metro
/// 호환 동작은 `.esm` 을 보수 처리해 왔다 (#2398). 본 함수는 _user 가 명시적으로_
/// `sideEffects: false` 를 선언한 모듈에만 그 신호를 신뢰 — 나머지는 conservative
/// 유지로 RN core 같은 미선언 케이스의 회귀 방지.
inline fn moduleHasEvaluationEffect(mod: *const Module) bool {
    if (mod.side_effects) return true;
    if (mod.wrap_kind == .cjs) return true;
    if (mod.exports_kind == .esm_with_dynamic_fallback) return true;
    if (mod.wrap_kind == .esm and !mod.side_effects_user_defined) return true;
    return false;
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

const ConstMaterializeProfile = struct {
    build_facts: ?profile.Category = null,
    candidate_gate: ?profile.Category = null,
    materialize: ?profile.Category = null,
    minify_resync: ?profile.Category = null,
    inner: constant_facts.MaterializeProfile = .{},
};

pub const TreeShaker = struct {
    allocator: std.mem.Allocator,
    /// Module storage 접근 포인터 (#1779 PR #2). 기존 `[]const Module` slice
    /// 필드를 대체. `analyze` 내부에서 `module.side_effects` 를 mutate 하므로 non-const.
    graph: *ModuleGraph,
    linker: *const Linker,
    included: std.DynamicBitSet,
    used_exports: std.StringHashMap(void),
    entry_set: std.DynamicBitSet,
    /// 모듈별 StmtInfo (심볼 기반 도달성 분석). analyze() 내 fixpoint 루프 전에 구축.
    module_stmt_infos: []?StmtInfos = &.{},
    /// 모듈별 도달성 bitset 캐시. crossModuleBFS가 채우고 같은 fixpoint 안에서
    /// seedOpaqueModule/processModuleImportsInner가 live 필터로 읽고,
    /// 수렴 후 emitter/statement_shaker가 소비한다.
    reachable_stmts: []?std.DynamicBitSet = &.{},
    /// 모듈별 sym_idx → import_binding_index 맵. 크로스-모듈 BFS에서 사용.
    sym_to_ib: []?[]?u32 = &.{},
    /// 모듈별 import_record_index → top-level stmt_index 맵. eval dependency 판정과
    /// require scan 이 같은 span search 를 반복하지 않도록 lazy 구축한다.
    import_record_stmt_indices: []?[]?u32 = &.{},
    /// seedOpaqueModule 재진입 방지용 visited bitset. crossModuleBFS에서 초기화.
    opaque_visited: ?std.DynamicBitSet = null,
    /// 모듈별 used export 존재 여부 (hasAnyUsedExportDirect 최적화: O(1) 조회).
    has_direct_used_export: []bool = &.{},
    /// prebuilt StmtInfo를 사용하는 모듈 마스크.
    /// prebuilt는 parse_arena가 소유하므로 deinit에서 해제하지 않는다.
    prebuilt_mask: ?std.DynamicBitSet = null,
    /// 모듈 인덱스가 다른 모듈의 `export * from` source 인지 표시. tryMarkReExportNsSubset
    /// 에서 chain 추적 시 O(M·E) scan 대신 O(1) 조회 (#1928).
    re_export_star_targets: ?std.DynamicBitSet = null,
    /// `export * as X from './src'` source lookup cache.
    /// followImport 가 named virtual namespace binding 마다 target.export_bindings 전체를
    /// 다시 훑지 않도록 module index -> exported namespace name -> source module index 를
    /// lazy 구축한다.
    re_export_namespace_sources: []?std.StringHashMapUnmanaged(u32) = &.{},
    /// seedExport(target module, exported name) 중복 처리 방지용 per-BFS scratch.
    /// 키 문자열은 모듈/바인딩 storage가 소유하므로 별도 복사하지 않는다.
    seeded_exports: std.HashMapUnmanaged(SeededExportKey, void, SeededExportKeyContext, 80) = .empty,
    /// numeric const fact propagation 의 DFS 스크래치. propagateNumericExportConstFacts /
    /// nodeContainsNumericConstRef 가 매 호출마다 ArrayList 를 새로 만들지 않도록 재사용.
    /// clearRetainingCapacity 로만 비운다.
    numeric_dfs_stack: std.ArrayList(NodeIndex) = .empty,
    /// Linker finalize 이후 AST mutation + semantic resync가 발생했는지.
    /// true면 old symbol id 기준 rename/mangle metadata를 재계산해야 한다.
    ast_mutated_after_link: bool = false,
    /// constant_facts.materialize 의 per-module forbidden/reachable 캐시. lazy-init —
    /// numeric pre-shake / post-pass worklist 가 같은 모듈을 다시 방문하면 매번 bitset +
    /// reachable 빌드를 재사용. AST mutation 시 해당 모듈만 invalidate.
    materialize_scratch: ?constant_facts.Scratch = null,

    const max_fixpoint_iterations: u32 = 100;

    const SeededExportKey = struct {
        module_index: u32,
        export_name: []const u8,
    };

    const SeededExportKeyContext = struct {
        pub fn hash(_: SeededExportKeyContext, key: SeededExportKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key.module_index));
            h.update(key.export_name);
            return h.final();
        }

        pub fn eql(_: SeededExportKeyContext, a: SeededExportKey, b: SeededExportKey) bool {
            return a.module_index == b.module_index and std.mem.eql(u8, a.export_name, b.export_name);
        }
    };

    const ReExportNsConsumerUsage = struct {
        opaque_all: bool = false,
        entries: std.StringHashMapUnmanaged(Entry) = .{},

        const Entry = struct {
            is_opaque: bool = false,
            props: std.StringHashMapUnmanaged(void) = .{},
        };

        fn deinit(self: *ReExportNsConsumerUsage, allocator: std.mem.Allocator) void {
            var vit = self.entries.valueIterator();
            while (vit.next()) |entry| entry.props.deinit(allocator);
            self.entries.deinit(allocator);
        }

        fn getOrPutEntry(
            self: *ReExportNsConsumerUsage,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) std.mem.Allocator.Error!*Entry {
            const gop = try self.entries.getOrPut(allocator, name);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            return gop.value_ptr;
        }

        fn markOpaque(
            self: *ReExportNsConsumerUsage,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) std.mem.Allocator.Error!void {
            const entry = try self.getOrPutEntry(allocator, name);
            entry.is_opaque = true;
        }

        fn addProps(
            self: *ReExportNsConsumerUsage,
            allocator: std.mem.Allocator,
            name: []const u8,
            props: []const []const u8,
        ) std.mem.Allocator.Error!void {
            const entry = try self.getOrPutEntry(allocator, name);
            if (entry.is_opaque) return;
            for (props) |prop| try entry.props.put(allocator, prop, {});
        }
    };

    pub fn init(allocator: std.mem.Allocator, graph: *ModuleGraph, linker: *const Linker) !TreeShaker {
        const mod_count = graph.moduleCount();
        var included = try std.DynamicBitSet.initEmpty(allocator, mod_count);
        errdefer included.deinit();
        var entry_set = try std.DynamicBitSet.initEmpty(allocator, mod_count);
        errdefer entry_set.deinit();

        return .{
            .allocator = allocator,
            .graph = graph,
            .linker = linker,
            .included = included,
            .used_exports = std.StringHashMap(void).init(allocator),
            .entry_set = entry_set,
        };
    }

    pub fn deinit(self: *TreeShaker) void {
        var kit = self.used_exports.keyIterator();
        while (kit.next()) |key| self.allocator.free(key.*);
        self.used_exports.deinit();
        self.included.deinit();
        self.entry_set.deinit();
        if (self.module_stmt_infos.len > 0) {
            for (self.module_stmt_infos, 0..) |*si, i| {
                if (si.*) |*infos| {
                    // prebuilt는 parse_arena가 소유하므로 여기서 해제하지 않는다.
                    if (self.prebuilt_mask) |mask| {
                        if (mask.isSet(i)) continue;
                    }
                    infos.deinit();
                }
            }
            self.allocator.free(self.module_stmt_infos);
        }
        if (self.prebuilt_mask) |*mask| mask.deinit();
        if (self.re_export_star_targets) |*mask| mask.deinit();
        if (self.re_export_namespace_sources.len > 0) {
            for (self.re_export_namespace_sources) |*maybe_map| {
                if (maybe_map.*) |*map| map.deinit(self.allocator);
            }
            self.allocator.free(self.re_export_namespace_sources);
        }
        self.seeded_exports.deinit(self.allocator);
        if (self.reachable_stmts.len > 0) {
            for (self.reachable_stmts) |*rs| {
                if (rs.*) |*bs| bs.deinit();
            }
            self.allocator.free(self.reachable_stmts);
        }
        if (self.sym_to_ib.len > 0) {
            for (self.sym_to_ib) |s| {
                if (s) |arr| self.allocator.free(arr);
            }
            self.allocator.free(self.sym_to_ib);
        }
        if (self.import_record_stmt_indices.len > 0) {
            for (self.import_record_stmt_indices) |s| {
                if (s) |arr| self.allocator.free(arr);
            }
            self.allocator.free(self.import_record_stmt_indices);
        }
        if (self.has_direct_used_export.len > 0) {
            self.allocator.free(self.has_direct_used_export);
        }
        self.numeric_dfs_stack.deinit(self.allocator);
        if (self.materialize_scratch) |*s| s.deinit();
    }

    /// 내부 단축 helper. `self.graph.getModule(ModuleIndex.fromUsize(idx))` 의 반복 방지.
    inline fn getModule(self: *const TreeShaker, idx: u32) ?*const Module {
        return self.graph.getModule(ModuleIndex.fromUsize(idx));
    }

    /// mutate 필요한 경로용.
    inline fn moduleAtMut(self: *const TreeShaker, idx: u32) ?*Module {
        return self.graph.moduleAtMut(ModuleIndex.fromUsize(idx));
    }

    /// `root` 에서 도달 가능한 노드를 DFS 로 순회하며 `visit_fn` 을 호출한다.
    /// `visit_fn` 이 true 를 반환하면 즉시 short-circuit. scratch stack 은 TreeShaker
    /// 가 보유한 것을 재사용 — 중첩 호출 금지.
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

    /// top-level `export const` 의 initializer 노드 인덱스를 순회한다 (write_count == 0).
    /// `visit_fn` 이 true 를 반환하면 즉시 short-circuit.
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

    /// DFS hot path 의 `const_values.get(sid)` HashMap lookup 을 피하려고 caller 가 미리
    /// 빌드한 numeric-symbol bitset 을 쓴다 (#2505 sub-item #2). bitset 은
    /// `moduleHasNumericExportConstChain` 가 한 번만 build → 같은 모듈 내 여러 init 을
    /// 도는 동안 재사용.
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
        return self.anyReachableNode(ast, root, NumericConstRefCtx{
            .symbol_ids = symbol_ids,
            .numeric_bitset = numeric_bitset,
        }, visitNumericConstRef);
    }

    fn visitChainExportInit(self: *TreeShaker, ctx: NumericConstRefCtx, ast: *const Ast, init_idx: NodeIndex) bool {
        return self.nodeContainsNumericConstRef(ast, ctx.symbol_ids, init_idx, ctx.numeric_bitset);
    }

    fn moduleHasNumericExportConstChain(
        self: *TreeShaker,
        ast: *const Ast,
        sem: ModuleSemanticData,
        const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
    ) bool {
        if (!constValuesContainNumber(const_values)) return false;
        // numeric symbol_id 만 미리 bitset 으로 — DFS 안에서 매 identifier_reference 마다
        // HashMap.get 하지 않도록 (#2505 sub-item #2). 모듈 안 export const 가 여러 개라도
        // 같은 bitset 을 재사용. alloc 실패면 보수적으로 false (이번 모듈 chain 후보 없다고 처리).
        var numeric_bitset = std.DynamicBitSet.initEmpty(self.allocator, sem.symbols.items.len) catch return false;
        defer numeric_bitset.deinit();
        var it = const_values.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.kind != .number) continue;
            const sid = entry.key_ptr.*;
            if (sid >= sem.symbols.items.len) continue;
            numeric_bitset.set(sid);
        }
        return self.anyExportedConstInit(ast, sem, NumericConstRefCtx{
            .symbol_ids = sem.symbol_ids,
            .numeric_bitset = &numeric_bitset,
        }, visitChainExportInit);
    }

    fn foldNumericExportSeeds(self: *TreeShaker, m: *Module, ast: *Ast) !bool {
        const minify_mod = @import("../transformer/minify.zig");
        const sem = if (m.semantic) |*sem| sem else return false;
        const arena_alloc = if (m.parse_arena) |*arena| arena.allocator() else return false;
        var has_exported_number = false;
        var folded = false;

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
            folded = true;
        }

        if (folded) {
            if (self.materialize_scratch) |*s| s.invalidate(@intFromEnum(m.index));
        }
        return has_exported_number;
    }

    fn moduleHasExportedNumberConstValue(_: *TreeShaker, sem: ModuleSemanticData) bool {
        for (sem.symbols.items) |sym| {
            if (!sym.isExported()) continue;
            if (sym.write_count != 0) continue;
            if (sym.const_kind == .number) return true;
        }
        return false;
    }

    fn anyModuleHasExportedNumberConst(self: *TreeShaker, mod_count: usize) bool {
        for (0..mod_count) |i| {
            const m = self.getModule(@intCast(i)) orelse continue;
            const sem = m.semantic orelse continue;
            if (self.moduleHasExportedNumberConstValue(sem)) return true;
        }
        return false;
    }

    /// numeric chain fold 를 reachability 확정 후 post-pass 에서 돌릴지.
    /// `minify_syntax` 모드는 pre-shake 의 `.all` materialize 가 이미 처리. 그 외 두 경로는
    /// pre-shake 만으로 부족: preserve_modules 는 pre-shake 자체를 건너뛰고, non-minify 는
    /// `propagateNumericExportConstFacts` 가 import edge 까지만 정리해 chain fold 는 후처리.
    fn shouldRunNumericPostPass(self: *const TreeShaker) bool {
        return self.graph.preserve_modules or !self.graph.transform_options_base.minify_syntax;
    }

    fn minifyAndResyncModule(
        self: *TreeShaker,
        m: *Module,
        sem: ModuleSemanticData,
        ast: *Ast,
        profile_cat: ?profile.Category,
    ) void {
        var scope = profile.beginMaybe(profile_cat);
        defer scope.end();

        const minify_mod = @import("../transformer/minify.zig");
        const root = ast.transformed_root orelse NodeIndex.none;
        const ctx = minify_mod.MinifyCtx.fromSemantic(&m.semantic.?, sem.symbol_ids, self.graph.transform_options_base.minify_syntax);
        minify_mod.minify(ast, ctx, self.allocator, root);
        self.markAstMutatedAndResync(m);
    }

    /// AST mutation 후 모듈 metadata 재동기화 + linker rename/mangling 재계산 신호 set.
    /// `resyncModuleMetadataAfterAstMutation` 만 호출하고 `ast_mutated_after_link` 를
    /// 빠뜨리면 `bundler.zig` 의 post-shake finalize gate 가 발화 안 해 stale rename
    /// 으로 emit 되는 회귀가 난다 — 두 동작은 항상 짝.
    fn markAstMutatedAndResync(self: *TreeShaker, m: *Module) void {
        // parse_arena 는 parse 단계에서 모든 모듈에 부착된다 (#1323). null 이면
        // 분석 산출물이 self.allocator 로 새서 leak 되므로 invariant 로 강제.
        std.debug.assert(m.parse_arena != null);
        self.graph.resyncModuleMetadataAfterAstMutation(m, m.parse_arena.?.allocator()) catch {
            m.prebuilt_stmt_info = null;
        };
        self.ast_mutated_after_link = true;
        self.invalidateImportRecordStmtIndices(@intFromEnum(m.index));
        if (self.materialize_scratch) |*s| s.invalidate(@intFromEnum(m.index));
    }

    fn invalidateImportRecordStmtIndices(self: *TreeShaker, idx: usize) void {
        if (idx >= self.import_record_stmt_indices.len) return;
        if (self.import_record_stmt_indices[idx]) |arr| {
            self.allocator.free(arr);
            self.import_record_stmt_indices[idx] = null;
        }
    }

    /// pre-shake materialize 직후 후속 BFS 가 읽는 linker populate* 만 좁게 재실행.
    /// rename/mangling 은 numeric post-pass 가 또 mutation 할 수 있어 모든 mutation 이
    /// settle 된 뒤 bundler 의 outer finalize 에서 한 번에 (#2502). `ast_mutated_after_link`
    /// 는 sticky 유지 — outer 가 항상 발화해야 새 symbol id 의 rename 이 emit 단계에 반영됨.
    fn refreshLinkMetadataAfterPreShakeMutation(self: *TreeShaker) void {
        if (!self.ast_mutated_after_link) return;
        if (self.graph.code_splitting) return;
        self.linker.refreshAfterAstMutation();
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
            .numeric_export_chain => self.moduleHasNumericExportConstChain(ast, sem, const_values),
        };
    }

    fn materializeCrossModuleConstFactsForIndex(
        self: *TreeShaker,
        module_index: usize,
        filter: ConstMaterializeFilter,
        const_profile: ConstMaterializeProfile,
    ) !bool {
        const m = self.moduleAtMut(@intCast(module_index)) orelse return false;
        if (m.import_bindings.len == 0) return false;
        const sem = m.semantic orelse return false;
        const ast = &(m.ast orelse return false);
        var const_values = blk: {
            var build_scope = profile.beginMaybe(const_profile.build_facts);
            defer build_scope.end();
            const build_profile = if (const_profile.build_facts != null)
                Linker.ConstValuesProfile{
                    .resolve = .shake_const_prepass_build_facts_resolve,
                    .lookup = .shake_const_prepass_build_facts_lookup,
                }
            else
                Linker.ConstValuesProfile{};
            break :blk try self.linker.buildCrossModuleConstValuesProfiled(m, sem, build_profile);
        };
        const should_materialize = blk: {
            var gate_scope = profile.beginMaybe(const_profile.candidate_gate);
            defer gate_scope.end();
            break :blk self.shouldMaterializeConstFacts(ast, sem, &const_values, filter);
        };
        if (!should_materialize) {
            const_values.deinit(self.allocator);
            return false;
        }

        if (self.materialize_scratch == null) {
            self.materialize_scratch = constant_facts.Scratch.init(self.allocator, self.graph.moduleCount()) catch null;
        }
        const scratch_ptr: ?*constant_facts.Scratch = if (self.materialize_scratch) |*s| s else null;
        const changed = blk: {
            var materialize_scope = profile.beginMaybe(const_profile.materialize);
            defer materialize_scope.end();
            break :blk constant_facts.materializeWithScratch(self.allocator, ast, sem.symbol_ids, &const_values, scratch_ptr, module_index, const_profile.inner);
        };
        const_values.deinit(self.allocator);
        if (!changed) return false;

        self.minifyAndResyncModule(m, sem, ast, const_profile.minify_resync);
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
                if (try self.materializeCrossModuleConstFactsForIndex(i, filter, const_profile)) any_changed = true;
            }
        } else {
            for (0..mod_count) |i| {
                if (try self.materializeCrossModuleConstFactsForIndex(i, filter, const_profile)) any_changed = true;
            }
        }
        return any_changed;
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
        if (!self.shouldVisitNumericPostPassModule(idx)) return;
        const m = self.getModule(idx) orelse return;
        if (m.import_bindings.len == 0) return;
        if (queued.isSet(idx)) return;
        try queue.append(self.allocator, idx);
        queued.set(idx);
    }

    fn materializeNumericConstFactsWorklist(self: *TreeShaker, mod_count: usize) !void {
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(self.allocator);
        var queued = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer queued.deinit();

        for (0..mod_count) |i| {
            try self.enqueueNumericPostPassModule(&queue, &queued, @intCast(i), mod_count);
        }

        while (queue.pop()) |idx| {
            if (idx < mod_count) queued.unset(idx);
            if (idx >= mod_count) continue;
            if (!self.shouldVisitNumericPostPassModule(idx)) continue;
            if (!try self.materializeCrossModuleConstFactsForIndex(idx, .numeric, .{})) continue;
            try self.enqueueStaticImporters(&queue, &queued, idx, mod_count);
        }
    }

    /// `Module.importers` (graph.linkDependency 가 채우는 양방향 인접 리스트) 의 항목을
    /// numeric BFS 큐에 넣는다. dynamic_importers 는 별도 리스트라 자동 제외 — dynamic
    /// import 는 runtime property 접근이라 numeric materialize 가 손댈 AST binding 이 없다.
    fn enqueueStaticImporters(
        self: *TreeShaker,
        queue: *std.ArrayList(u32),
        queued: *std.DynamicBitSet,
        idx: u32,
        mod_count: usize,
    ) !void {
        const m = self.getModule(idx) orelse return;
        for (m.importers.items) |imp| {
            const ii = @intFromEnum(imp);
            if (ii >= mod_count) continue;
            if (queued.isSet(ii)) continue;
            try queue.append(self.allocator, @intCast(ii));
            queued.set(ii);
        }
    }

    fn propagateNumericExportConstFacts(
        self: *TreeShaker,
        mod_count: usize,
        const_profile: ConstMaterializeProfile,
    ) !void {
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(self.allocator);
        // Same importer can be reached from many exported numeric leaves. Keep the
        // worklist unique while pending, but allow re-enqueue after a module is
        // popped so later AST mutations still propagate to its importers.
        var queued = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer queued.deinit();
        // re-export-only 모듈은 importer 가 큐를 비울 때마다 한 번만 forwarding 하면 충분 —
        // 다시 들어오면 같은 importer 들을 무한히 enqueue 해 BFS 가 폭발한다.
        var forwarded_re_exports = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer forwarded_re_exports.deinit();
        {
            var seed_scope = profile.begin(.shake_const_prepass_numeric_seed_scan);
            defer seed_scope.end();

            for (0..mod_count) |i| {
                const m = self.moduleAtMut(@intCast(i)) orelse continue;
                const ast = &(m.ast orelse continue);
                if (try self.foldNumericExportSeeds(m, ast)) {
                    try self.enqueueStaticImporters(&queue, &queued, @intCast(i), mod_count);
                }
            }
        }

        {
            var queue_scope = profile.begin(.shake_const_prepass_numeric_queue);
            defer queue_scope.end();

            while (queue.pop()) |idx| {
                if (idx < mod_count) queued.unset(idx);
                if (idx >= mod_count) continue;
                if (try self.materializeCrossModuleConstFactsForIndex(idx, .numeric_export_chain, const_profile)) {
                    try self.enqueueStaticImporters(&queue, &queued, idx, mod_count);
                    continue;
                }

                if (forwarded_re_exports.isSet(idx)) continue;
                const m = self.getModule(idx) orelse continue;
                var has_re_export = false;
                for (m.export_bindings) |eb| {
                    if (eb.kind.isAnyReExport()) {
                        has_re_export = true;
                        break;
                    }
                }
                if (!has_re_export) continue;
                forwarded_re_exports.set(idx);
                try self.enqueueStaticImporters(&queue, &queued, idx, mod_count);
            }
        }
    }

    /// Tree-shaking 분석 (fixpoint 방식).
    ///
    /// 포함된 모듈의 import만 export 사용으로 카운트한다.
    /// included는 단조가 아님 — 축소(미사용 제거)와 확장(canonical/side-effect 전파)이 교차.
    /// 변경이 없을 때 수렴하며, 실제로는 2-3회 이내.
    pub fn analyze(self: *TreeShaker, entry_points: []const []const u8) !void {
        const mod_count = self.graph.moduleCount();

        // re_export_star_targets bitset 한 번 build — tryMarkReExportNsSubset 가 fixpoint
        // 안에서 매번 O(M·E) scan 하지 않도록.
        {
            var setup_scope = profile.begin(.shake_setup);
            defer setup_scope.end();

            var re_star_targets = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
            errdefer re_star_targets.deinit();
            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                for (m.export_bindings) |eb| {
                    if (eb.kind != .re_export_star) continue;
                    const rec_idx = eb.import_record_index orelse continue;
                    if (rec_idx >= m.import_records.len) continue;
                    const src = m.import_records[rec_idx].resolved;
                    if (src == .none) continue;
                    re_star_targets.set(@intFromEnum(src));
                }
            }
            self.re_export_star_targets = re_star_targets;

            // entry_set 먼저 계산 (자동 순수 판별에서 진입점 제외용).
            // `inject` and `runBeforeMain` are not output entries, but they are
            // execution roots and may be import-only prelude modules.
            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                for (entry_points) |ep| {
                    if (std.mem.eql(u8, m.path, ep)) {
                        self.entry_set.set(i);
                        break;
                    }
                }
                if (self.entry_set.isSet(i)) continue;
                for (self.graph.inject_files) |inject_path| {
                    if (std.mem.eql(u8, m.path, inject_path)) {
                        self.entry_set.set(i);
                        break;
                    }
                }
                if (self.entry_set.isSet(i)) continue;
                for (self.graph.run_before_main_files) |rbm_path| {
                    if (std.mem.eql(u8, m.path, rbm_path)) {
                        self.entry_set.set(i);
                        break;
                    }
                }
            }
        }

        // Linker가 증명한 cross-module constant를 tree-shaking 전 AST에 먼저 반영한다.
        // 그래야 `if (DEV) heavy()` 같은 dead branch 안 import가 BFS seed로 번지지 않는다.
        // preserve-modules는 원본 모듈 경계가 출력 계약이므로, import edge를 제거할 수
        // 있는 materialize는 reachability 확정 뒤 numeric post-pass에서만 수행한다.
        {
            var const_scope = profile.begin(.shake_const_prepass);
            defer const_scope.end();

            const prepass_const_profile = ConstMaterializeProfile{
                .build_facts = .shake_const_prepass_build_facts,
                .candidate_gate = .shake_const_prepass_candidate_gate,
                .materialize = .shake_const_prepass_materialize,
                .minify_resync = .shake_const_prepass_minify_resync,
                .inner = .{
                    .forbidden = .shake_const_prepass_forbidden,
                    .reachable = .shake_const_prepass_reachable,
                    .replace = .shake_const_prepass_replace,
                },
            };

            if (!self.graph.preserve_modules) {
                if (self.graph.transform_options_base.minify_syntax) {
                    var full_scope = profile.begin(.shake_const_prepass_full_materialize);
                    defer full_scope.end();
                    _ = try self.materializeCrossModuleConstFacts(mod_count, .all, false, prepass_const_profile);
                } else {
                    var numeric_scope = profile.begin(.shake_const_prepass_numeric_propagate);
                    defer numeric_scope.end();
                    try self.propagateNumericExportConstFacts(mod_count, prepass_const_profile);
                }
            }

            {
                var node_buffer_scope = profile.begin(.shake_const_prepass_node_buffer);
                defer node_buffer_scope.end();
                if (self.graph.resolve_cache.platform == .node) {
                    try self.applyNodeBufferCapabilityFacts();
                }
            }
            {
                var link_refresh_scope = profile.begin(.shake_const_prepass_link_refresh);
                defer link_refresh_scope.end();
                self.refreshLinkMetadataAfterPreShakeMutation();
            }
        }

        // 자동 순수 판별: 진입점이 아닌 모듈의 top-level이 모두 순수하면 side_effects=false
        // (rolldown/esbuild 동작: package.json sideEffects 없어도 자동 감지)
        // 단, package.json sideEffects에 의해 결정된 값(user_defined)은 덮어쓰지 않는다
        // (rolldown DeterminedSideEffects::UserDefined 포팅).
        // require.context match 로 등록된 모듈 (is_context_dep) 도 건드리지 않음 —
        // runtime require 로 접근하므로 AST 상 pure 여도 제거하면 안 됨.
        {
            var purity_scope = profile.begin(.shake_purity);
            defer purity_scope.end();

            for (0..mod_count) |i| {
                const m = self.moduleAtMut(@intCast(i)) orelse continue;
                if (!m.side_effects) continue;
                if (m.side_effects_user_defined) continue;
                if (self.entry_set.isSet(i)) continue;
                if (m.is_context_dep) continue;
                if (m.ast) |ast| {
                    const unresolved = if (m.semantic) |*s| &s.unresolved_references else null;
                    if (isModulePure(&ast, unresolved)) {
                        m.side_effects = false;
                    }
                }
            }
        }

        {
            var setup_scope = profile.begin(.shake_setup);
            defer setup_scope.end();

            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                const is_entry = self.entry_set.isSet(i);
                if (is_entry or m.is_context_dep) self.included.set(i);
                if (!is_entry) continue;
                for (m.dependencies.items) |dep_idx| {
                    const dep = self.graph.getModule(dep_idx) orelse continue;
                    if (moduleHasEvaluationEffect(dep)) {
                        self.included.set(@intFromEnum(dep_idx));
                    }
                }
            }
        }

        // dynamic import()의 target 모듈 집합. 정적 import_binding이 없어 심볼 도달성
        // 분석에서 누락되므로 별도 추적해 prune 단계에서 보호한다 (#1260).
        var dyn_import_targets = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer dyn_import_targets.deinit();
        {
            var setup_scope = profile.begin(.shake_setup);
            defer setup_scope.end();

            var dyn_it = self.graph.modulesIterator();
            while (dyn_it.next()) |m| {
                for (m.import_records) |rec| {
                    if (rec.kind != .dynamic_import or rec.resolved.isNone()) continue;
                    const target = @intFromEnum(rec.resolved);
                    if (target < mod_count) {
                        dyn_import_targets.set(target);
                        // dynamic import는 runtime에 임의 export에 접근할 수 있으므로
                        // 모든 export를 사용으로 마킹 (entry와 동일 취급).
                        self.included.set(target);
                        try self.markAllExportsUsed(@intCast(target));
                    }
                }
            }

            // has_direct_used_export 배열 초기화 (hasAnyUsedExportDirect O(1) 조회용)
            const has_due = try self.allocator.alloc(bool, mod_count);
            @memset(has_due, false);
            self.has_direct_used_export = has_due;

            // entry / context_dep 모듈의 모든 export를 사용으로 마킹 — runtime require 로
            // 접근하는 모듈은 어떤 export 가 쓰일지 정적으로 알 수 없음 (dynamic import 와 유사).
            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                if (self.entry_set.isSet(i) or m.is_context_dep) try self.markAllExportsUsed(@intCast(i));
            }
        }

        // StmtInfo 구축을 fixpoint 루프 전에 수행(#1558).
        // fixpoint 중에 BFS가 statement-level reachability를 사용하려면 미리 필요.
        // 모든 non-entry non-wrapped 모듈에 대해 구축 — included 여부는 이후 fixpoint에서 확장.
        var module_stmt_infos: []?StmtInfos = undefined;
        var reachable_stmts: []?std.DynamicBitSet = undefined;
        {
            var stmt_scope = profile.begin(.shake_stmt_info);
            defer stmt_scope.end();

            module_stmt_infos = try self.allocator.alloc(?StmtInfos, mod_count);
            for (module_stmt_infos) |*si| si.* = null;
            self.module_stmt_infos = module_stmt_infos;

            reachable_stmts = try self.allocator.alloc(?std.DynamicBitSet, mod_count);
            for (reachable_stmts) |*rs| rs.* = null;
            self.reachable_stmts = reachable_stmts;

            var prebuilt_mask = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
            self.prebuilt_mask = prebuilt_mask;
            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                // .esm wrap 은 emit shape (lazy init) 일 뿐이라 reachability 분석에 의미 영향
                // 없지만, 기존 opaque 가정에 의존하는 코드 경로 (barrel re-export indirection 의
                // emit-vs-shake 좌표 등) 가 있어 _명시적으로 pure 표시된_ 모듈에만 StmtInfo
                // 빌드 (#2398). `sideEffects: false` 가 user 의 "drop 가능" 신호이므로 그 신호가
                // 있을 때만 정밀 DCE — RN core 처럼 sideEffects 미명시 모듈은 기존 보수 동작 유지.
                // rolldown 의 `try_extract_lazy_barrel_info` (DeterminedSideEffects::UserDefined(false))
                // 와 동일 게이트.
                const is_user_declared_pure = m.side_effects_user_defined and !m.side_effects;
                if (m.wrap_kind == .esm and !is_user_declared_pure) continue;

                if (m.wrap_kind != .cjs) {
                    if (m.prebuilt_stmt_info) |prebuilt| {
                        module_stmt_infos[i] = prebuilt;
                        prebuilt_mask.set(i);
                        continue;
                    }
                }

                const sem = m.semantic orelse continue;
                const ast = &(m.ast orelse continue);
                module_stmt_infos[i] = stmt_info_mod.build(
                    self.allocator,
                    ast,
                    sem.symbols.items,
                    sem.symbol_ids,
                    &sem.unresolved_references,
                    m.wrap_kind == .cjs,
                ) catch null;
            }
        }

        // --- Unified fixpoint (#1558 Step 3+4) ---
        // 매 iteration:
        //   (a) BFS: entry/"*" seed에서 statement reachability 전파, used_exports 마킹
        //       enqueue에서 sym_to_ib lazy 구축 → 동일 iter 내 followImport 정상 동작
        //   (b) processModuleImports(live_mod_idx): BFS-reachable statement 안 import만 마킹
        //   (c) re-export source include / side-effect 전파
        // used_exports 또는 included 변화 없으면 수렴. BFS만이 used_exports 진리 소스.
        var iteration: u32 = 0;
        while (iteration < max_fixpoint_iterations) : (iteration += 1) {
            var fixpoint_scope = profile.begin(.shake_fixpoint);
            defer fixpoint_scope.end();

            var changed = false;
            const used_count_before = self.used_exports.count();
            const included_count_before = self.included.count();

            try self.buildSymToIbMaps();
            try self.crossModuleBFS(module_stmt_infos, reachable_stmts);

            for (0..mod_count) |i| {
                if (!self.included.isSet(i)) continue;
                const m = self.getModule(@intCast(i)) orelse continue;
                const live_idx: ?u32 = if (m.wrap_kind == .esm) null else @intCast(i);
                if (try self.processModuleImportsInner(m.*, live_idx)) changed = true;
            }

            if (try self.includeReExportSources(true)) changed = true;

            {
                var eval_scope = profile.begin(.shake_fixpoint_eval_deps);
                defer eval_scope.end();

                for (0..mod_count) |i| {
                    if (!self.included.isSet(i)) continue;
                    const m = self.getModule(@intCast(i)) orelse continue;
                    const live_idx: ?u32 = if (m.wrap_kind == .esm) null else @intCast(i);
                    for (m.import_records, 0..) |rec, rec_i| {
                        if (rec.resolved.isNone()) continue;
                        const target = @intFromEnum(rec.resolved);
                        const tmod = self.graph.getModule(rec.resolved) orelse continue;

                        const preserve = try self.shouldPreserveImportRecordForEvaluation(m, @intCast(i), @intCast(rec_i), live_idx);
                        const must_include = rec.kind == .require or
                            ((rec.kind == .side_effect or rec.kind == .re_export) and preserve) or
                            (moduleHasEvaluationEffect(tmod) and preserve);
                        if (!must_include) continue;
                        if (!self.included.isSet(target)) {
                            self.included.set(target);
                            changed = true;
                        }
                        // require() 는 namespace 접근 → 어떤 export 가 읽힐지 정적 분석 불가.
                        // 보수적으로 target 의 모든 export 를 used 로 마킹. .cjs 와 .esm wrap 둘 다
                        // (#2398: 이전엔 .esm 의 StmtInfo 가 안 만들어져 reachability 가 conservative
                        // true 라 자동 보존됐지만, 본 PR 에서 .esm StmtInfo 를 빌드하면서 명시 마킹 필요).
                        if (rec.kind == .require and tmod.wrap_kind.isWrapped() and preserve) {
                            try self.markAllExportsUsed(@intCast(target));
                        }
                    }
                }
            }

            if (self.used_exports.count() != used_count_before) changed = true;
            if (self.included.count() != included_count_before) changed = true;
            if (!changed) break;
        }

        // 미사용 sideEffects=false 모듈 제거.
        {
            var prune_scope = profile.begin(.shake_prune);
            defer prune_scope.end();

            for (0..mod_count) |i| {
                if (!self.included.isSet(i)) continue;
                const m = self.getModule(@intCast(i)) orelse continue;
                if (self.entry_set.isSet(i) or moduleHasEvaluationEffect(m)) continue;
                if (dyn_import_targets.isSet(i)) continue; // #1260: dynamic import target 보호
                if (m.is_context_dep) continue; // require.context match 는 runtime require 대상
                if (!self.hasAnyUsedExport(@intCast(i)) and !self.hasAnyUsedExportDirect(@intCast(i))) {
                    self.included.unset(i);
                }
            }
        }

        // Numeric chain 축약은 번들 크기/그래프 성능에 직접 영향을 주므로 `--minify` 없이도
        // 실행한다. used_exports/reachability 판정이 끝난 뒤로 미루는 건 디버그용 tree-shaker
        // 기대값 보존. 어떤 모듈도 numeric export 가 없으면 build/scan 비용 자체를 회피.
        {
            var numeric_scope = profile.begin(.shake_numeric_postpass);
            defer numeric_scope.end();

            if (self.shouldRunNumericPostPass() and self.anyModuleHasExportedNumberConst(mod_count)) {
                try self.materializeNumericConstFactsWorklist(mod_count);
            }
        }

        // ModuleInfo `isIncluded` 노출용 — 최종 included BitSet 을 Module 에 mirror.
        // chunk gen / NAPI 가 BitSet 직접 보유 안 해도 `m.is_included` 로 조회 가능.
        {
            var mirror_scope = profile.begin(.shake_mirror);
            defer mirror_scope.end();

            for (0..mod_count) |i| {
                const m = self.moduleAtMut(@intCast(i)) orelse continue;
                m.is_included = self.included.isSet(i);
            }
        }
    }

    pub fn isStmtReachable(self: *const TreeShaker, module_index: u32, stmt_idx: u32) bool {
        if (module_index >= self.reachable_stmts.len) return true;
        const reachable = self.reachable_stmts[module_index] orelse return true;
        return reachable.isSet(stmt_idx);
    }

    pub fn getModuleStmtInfos(self: *const TreeShaker, module_index: u32) ?StmtInfos {
        if (module_index >= self.module_stmt_infos.len) return null;
        return self.module_stmt_infos[module_index];
    }

    pub fn isIncluded(self: *const TreeShaker, module_index: u32) bool {
        if (module_index >= self.graph.moduleCount()) return false;
        return self.included.isSet(module_index);
    }

    pub fn isExportUsed(self: *const TreeShaker, module_index: u32, export_name: []const u8) bool {
        var key_buf: [4096]u8 = undefined;
        const key = types.makeModuleKeyBuf(&key_buf, module_index, export_name);
        return self.used_exports.contains(key);
    }

    fn markSeedExportVisited(self: *TreeShaker, module_index: u32, export_name: []const u8) !bool {
        const entry = try self.seeded_exports.getOrPut(self.allocator, .{
            .module_index = module_index,
            .export_name = export_name,
        });
        return !entry.found_existing;
    }

    /// import binding의 심볼이 해당 모듈에서 reachable statement에서 참조되는지 확인.
    /// emitter가 export_bindings 필터링에 사용.
    pub fn isImportLiveInModule(self: *const TreeShaker, module_index: u32, local_name: []const u8) bool {
        if (module_index >= self.reachable_stmts.len) return true;
        const reachable = self.reachable_stmts[module_index] orelse return true;
        const infos = if (module_index < self.module_stmt_infos.len)
            (self.module_stmt_infos[module_index] orelse return true)
        else
            return true;
        const m = self.getModule(module_index) orelse return true;
        const sem = m.semantic orelse return true;
        if (sem.scope_maps.len == 0) return true;
        const sym_idx = sem.scope_maps[0].get(local_name) orelse return false;

        // 역인덱스로 이 심볼을 참조하는 statement 중 reachable한 것이 있는지 확인
        for (infos.referencingStmts(@intCast(sym_idx))) |si| {
            if (!reachable.isSet(si)) continue;
            if (isImportDeclarationStmt(m, infos, @intCast(si))) continue;
            return true;
        }
        return false;
    }

    /// 모듈의 top-level 문장이 모두 순수한지 판별.
    /// 순수: import/export 선언, 함수/클래스 선언, 변수 선언(초기값이 순수), @__PURE__ call.
    /// 불순: 일반 call expression, assignment to global, etc.
    fn isModulePure(ast: *const Ast, unresolved_globals: ?*const purity.GlobalRefSet) bool {
        if (ast.nodes.items.len == 0) return false;
        // program 노드는 파서가 마지막에 추가 — 마지막 노드
        const root = ast.nodes.items[ast.nodes.items.len - 1];
        if (root.tag != .program) return false;
        const stmts = root.data.list;
        if (stmts.len == 0) return false; // 빈 모듈은 기본값 유지
        if (stmts.start + stmts.len > ast.extra_data.items.len) return false;

        const stmt_indices = ast.extra_data.items[stmts.start .. stmts.start + stmts.len];
        for (stmt_indices) |raw| {
            const idx: NodeIndex = @enumFromInt(raw);
            if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
            const stmt = ast.nodes.items[@intFromEnum(idx)];
            if (!isStatementPure(ast, stmt, unresolved_globals)) return false;
        }
        return true;
    }

    fn isStatementPure(ast: *const Ast, stmt: Node, unresolved_globals: ?*const purity.GlobalRefSet) bool {
        return switch (stmt.tag) {
            .import_declaration,
            .export_all_declaration,
            => true,

            .export_named_declaration => {
                if (!ast.hasExtra(stmt.data.extra, 0)) return true;
                const decl_idx = ast.readExtraNode(stmt.data.extra, 0);
                if (decl_idx.isNone()) return true;
                if (@intFromEnum(decl_idx) >= ast.nodes.items.len) return true;
                const decl = ast.nodes.items[@intFromEnum(decl_idx)];
                return isStatementPure(ast, decl, unresolved_globals);
            },

            .export_default_declaration => {
                const inner_idx = stmt.data.unary.operand;
                if (inner_idx.isNone() or @intFromEnum(inner_idx) >= ast.nodes.items.len) return false;
                const inner = ast.nodes.items[@intFromEnum(inner_idx)];
                return switch (inner.tag) {
                    .function_declaration => true,
                    .class_declaration => !purity.classHasSideEffects(ast, inner, unresolved_globals),
                    else => purity.isExprPure(ast, inner_idx, unresolved_globals),
                };
            },

            .function_declaration => true,
            .class_declaration => !purity.classHasSideEffects(ast, stmt, unresolved_globals),

            .ts_interface_declaration,
            .ts_type_alias_declaration,
            => true,

            .ts_enum_declaration,
            .ts_module_declaration,
            => false,

            .variable_declaration => purity.isVarDeclPure(ast, stmt, unresolved_globals),
            .expression_statement,
            .if_statement,
            => !purity.stmtHasSideEffects(ast, stmt, unresolved_globals),

            .empty_statement => true,

            else => false,
        };
    }

    // ============================================================
    // Internal
    // ============================================================

    /// 한 모듈의 sym_to_ib 맵을 lazy 구축 (BFS가 included 확장 시 즉시 호출 가능).
    /// self.sym_to_ib 배열 자체는 첫 호출에서 할당.
    fn ensureSymToIbForModule(self: *TreeShaker, mod_idx: u32) !void {
        if (self.sym_to_ib.len == 0) {
            const maps = try self.allocator.alloc(?[]?u32, self.graph.moduleCount());
            for (maps) |*m| m.* = null;
            self.sym_to_ib = maps;
        }
        if (mod_idx >= self.sym_to_ib.len) return;
        if (self.sym_to_ib[mod_idx] != null) return;
        const mod = self.getModule(mod_idx) orelse return;
        const sem = mod.semantic orelse return;
        if (sem.scope_maps.len == 0 or mod.import_bindings.len == 0) return;
        const arr = try self.allocator.alloc(?u32, sem.symbols.items.len);
        for (arr) |*a| a.* = null;
        for (mod.import_bindings, 0..) |ib, ib_idx| {
            const sym_idx = ib.local_symbol.semanticIndex() orelse continue;
            if (sym_idx < arr.len) arr[sym_idx] = @intCast(ib_idx);
        }
        self.sym_to_ib[mod_idx] = arr;
    }

    /// 모든 included 모듈의 sym_to_ib 맵 구축/확장.
    fn buildSymToIbMaps(self: *TreeShaker) !void {
        var scope = profile.begin(.shake_fixpoint_sym_to_ib);
        defer scope.end();

        for (0..self.graph.moduleCount()) |i| {
            if (!self.included.isSet(i)) continue;
            try self.ensureSymToIbForModule(@intCast(i));
        }
    }

    const BfsItem = struct { mod: u32, stmt: u32 };

    /// 크로스-모듈 BFS: import binding → resolveExportChain → 타겟 statement로 점프.
    fn crossModuleBFS(
        self: *TreeShaker,
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        var scope = profile.begin(.shake_fixpoint_bfs);
        defer scope.end();

        self.seeded_exports.clearRetainingCapacity();

        var queue: std.ArrayListUnmanaged(BfsItem) = .empty;
        defer queue.deinit(self.allocator);

        const mod_count = self.graph.moduleCount();
        var ov = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer ov.deinit();
        self.opaque_visited = ov;

        // 시드 1: entry module의 export 선언 statement + side-effect statement
        {
            var seed_scope = profile.begin(.shake_fixpoint_bfs_seed);
            defer seed_scope.end();

            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                const infos = module_stmt_infos[i] orelse {
                    // StmtInfo 없는 포함 모듈 (entry, CJS): import를 직접 시드
                    if (self.included.isSet(i) and (self.entry_set.isSet(i) or m.wrap_kind.isWrapped())) {
                        try self.seedOpaqueModule(@intCast(i), &queue, module_stmt_infos, reachable_stmts);
                    }
                    continue;
                };
                if (!self.included.isSet(i)) continue;

                // reachable bitset 초기화
                if (reachable_stmts[i] == null) {
                    reachable_stmts[i] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
                }

                // entry는 번들 진입점이지만 pure local declaration은 실행 의미가 없다.
                // side-effect statement와 entry export seed만 살리고, local-only pure statement는
                // BFS dependency로 필요할 때만 도달시킨다.
                // side_effects=true 모듈은 side-effect stmt만 시드.
                // side_effects=false 모듈은 enqueue의 lazy 시드로 처리 (사용 시에만).
                if (self.entry_set.isSet(i)) {
                    var has_entry_side_effect_stmt = false;
                    for (infos.stmts) |stmt| {
                        if (stmt.has_side_effects) {
                            has_entry_side_effect_stmt = true;
                            break;
                        }
                    }
                    const prune_pure_entry_locals = self.graph.transform_options_base.minify_syntax and
                        (has_entry_side_effect_stmt or m.export_bindings.len > 0);
                    for (infos.stmts, 0..) |stmt, si| {
                        if (!prune_pure_entry_locals or stmt.has_side_effects) {
                            try self.enqueue(@intCast(i), @intCast(si), reachable_stmts, &queue);
                        }
                    }
                } else if (m.side_effects and m.side_effects_user_defined) {
                    for (infos.stmts, 0..) |_, si| {
                        try self.enqueue(@intCast(i), @intCast(si), reachable_stmts, &queue);
                    }
                } else if (m.side_effects) {
                    for (infos.stmts, 0..) |stmt, si| {
                        if (stmt.has_side_effects) {
                            try self.enqueue(@intCast(i), @intCast(si), reachable_stmts, &queue);
                        }
                    }
                }

                // used export 선언 statement 시드. 시드 대상:
                //   (1) entry: 번들 외부 사용자가 접근 가능 — 모든 export live.
                //   (2) ALL_EXPORTS_SENTINEL 마킹된 모듈: dynamic import target(#1260) 또는 export * 전파 대상.
                // non-entry·sentinel 없음: followImport만으로 도달해야 가짜 used 확산을 막는다.
                const is_bfs_seed = self.entry_set.isSet(i) or self.isExportUsed(@intCast(i), ALL_EXPORTS_SENTINEL);
                if (is_bfs_seed) {
                    const sem = m.semantic orelse continue;
                    if (sem.scope_maps.len == 0) continue;
                    for (m.export_bindings) |eb| {
                        if (eb.kind.isReExportAll()) continue;
                        const sym_idx = eb.symbol.semanticIndex() orelse continue;
                        try self.enqueueSymbolLiveStatements(@intCast(i), infos, sym_idx, reachable_stmts, &queue);
                    }
                    // dynamic import target도 re-export 체인 따라 transitive 모듈까지
                    // 전파해야 함(#1260). seedOpaqueModule은 opaque_visited로 중복 방지.
                    try self.seedOpaqueModule(@intCast(i), &queue, module_stmt_infos, reachable_stmts);
                }
            }
        }

        // BFS 루프
        {
            var queue_scope = profile.begin(.shake_fixpoint_bfs_queue);
            defer queue_scope.end();

            var head: u32 = 0;
            while (head < queue.items.len) : (head += 1) {
                const item = queue.items[head];
                const infos = module_stmt_infos[item.mod] orelse continue;
                if (item.stmt >= infos.stmts.len) continue;

                // item 단위 invariant — referenced_symbols 루프 밖으로 한 번만 계산.
                const owner = self.getModule(item.mod);
                const skip_import_followup = if (owner) |o| isImportDeclarationStmt(o, infos, item.stmt) else true;

                for (infos.stmts[item.stmt].referenced_symbols) |ref_sym| {
                    // (1) 로컬 심볼: 같은 모듈의 종속 statement
                    if (infos.declaredStmtBySymbol(ref_sym)) |dep_stmt| {
                        try self.enqueue(item.mod, dep_stmt, reachable_stmts, &queue);
                    }

                    // (1b) 같은 심볼에 대한 비선언 writer (예: TS 가 emit 하는 `var _a; ... _a = AST;`).
                    // declare 경로로는 var-only 선언만 살아남고 실제 값을 채우는 후속 할당이 누락되어
                    // `_a is not a constructor` 류 회귀가 발생한다.
                    for (infos.writerStmts(ref_sym)) |writer_stmt| {
                        try self.enqueue(item.mod, writer_stmt, reachable_stmts, &queue);
                    }

                    // (2) import binding: 타겟 모듈로 점프
                    if (skip_import_followup) continue;
                    if (item.mod < self.sym_to_ib.len) {
                        if (self.sym_to_ib[item.mod]) |sym_map| {
                            if (ref_sym < sym_map.len) {
                                if (sym_map[ref_sym]) |ib_idx| {
                                    try self.followImport(item.mod, ib_idx, item.stmt, &queue, module_stmt_infos, reachable_stmts);
                                }
                            }
                        }
                    }
                }

                if (owner) |o| {
                    var require_scope = profile.begin(.shake_fixpoint_bfs_require_scan);
                    defer require_scope.end();

                    for (o.import_records, 0..) |rec, rec_i| {
                        if (rec.kind != .require) continue;
                        if (rec.resolved.isNone()) continue;
                        if (!try self.importRecordBelongsToStmt(@intCast(item.mod), infos, @intCast(item.stmt), @intCast(rec_i))) continue;
                        const target_mod_idx = @intFromEnum(rec.resolved);
                        const target_module = self.graph.getModule(rec.resolved) orelse continue;
                        if (target_module.wrap_kind != .cjs) continue;
                        if (!self.isExportUsed(item.mod, ALL_EXPORTS_SENTINEL) and
                            !self.isExportUsed(@intCast(target_mod_idx), ALL_EXPORTS_SENTINEL) and
                            self.hasAnyUsedExportDirect(@intCast(target_mod_idx)) and
                            moduleExportsRequireProxyMatches(o, infos, @intCast(item.stmt), rec.resolved))
                        {
                            const target_infos = module_stmt_infos[target_mod_idx] orelse {
                                try self.markAndSeedAllStmts(@intCast(target_mod_idx), &queue, module_stmt_infos, reachable_stmts);
                                continue;
                            };
                            try self.seedSideEffectStmts(@intCast(target_mod_idx), target_infos, &queue, reachable_stmts);
                            continue;
                        }
                        try self.markAndSeedAllStmts(@intCast(target_mod_idx), &queue, module_stmt_infos, reachable_stmts);
                    }
                }
            }
        }

        // BFS 후: reachable statement 기반 used_exports 추가 마킹
        // BFS 중 markExportUsed로 마킹된 것은 유지 (clearUsedExports 하지 않음)
        {
            var final_scope = profile.begin(.shake_fixpoint_bfs_final_mark_exports);
            defer final_scope.end();

            for (0..mod_count) |i| {
                const m = self.getModule(@intCast(i)) orelse continue;
                const infos = module_stmt_infos[i] orelse continue;
                const sem = m.semantic orelse continue;
                if (sem.scope_maps.len == 0) continue;
                for (m.export_bindings) |eb| {
                    if (eb.kind.isReExportAll()) continue;
                    const sym_idx = eb.symbol.semanticIndex() orelse continue;
                    if (infos.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
                        if (reachable_stmts[i] != null and reachable_stmts[i].?.isSet(stmt_idx)) {
                            try self.markExportUsed(@intCast(i), eb.exported_name);
                        }
                    }
                }
            }
        }
    }

    fn enqueue(self: *TreeShaker, mod: u32, stmt: u32, reachable: []?std.DynamicBitSet, queue: *std.ArrayListUnmanaged(BfsItem)) std.mem.Allocator.Error!void {
        if (mod >= reachable.len) return;
        if (reachable[mod] == null) return;
        if (reachable[mod].?.isSet(stmt)) return;
        reachable[mod].?.set(stmt);
        try queue.append(self.allocator, .{ .mod = mod, .stmt = stmt });

        // BFS가 새로 방문하는 모듈의 sym_to_ib 맵 lazy 구축(#1558).
        // 기존엔 fixpoint 수렴 후 buildSymToIbMaps가 일괄 구축했지만, fixpoint 내부에서
        // BFS가 seedExport로 새 모듈을 include 시킬 때 해당 모듈의 sym_to_ib가 없으면
        // dequeue 시 followImport 불가 → 모듈-내 참조가 reachable 되지 않는 회귀 발생.
        try self.ensureSymToIbForModule(mod);

        // 새 심볼이 reachable이 되면, 같은 모듈의 side-effect statement 중
        // 해당 심볼을 참조하는 것을 lazy 시드.
        // 예: Object3D가 reachable → Object3D.DEFAULT_UP = ... 도 시드
        // 역인덱스 활용: O(D×K) where K = avg side-effect refs per symbol
        if (mod < self.module_stmt_infos.len) {
            var side_effect_scope = profile.begin(.shake_fixpoint_bfs_enqueue_side_effects);
            defer side_effect_scope.end();

            if (self.module_stmt_infos[mod]) |infos| {
                if (stmt < infos.stmts.len) {
                    for (infos.stmts[stmt].declared_symbols) |declared_sym| {
                        for (infos.sideEffectStmts(declared_sym)) |si| {
                            if (!reachable[mod].?.isSet(si)) {
                                reachable[mod].?.set(si);
                                try queue.append(self.allocator, .{ .mod = @intCast(mod), .stmt = @intCast(si) });
                            }
                        }
                    }
                }
            }
        }
    }

    fn enqueueSymbolLiveStatements(
        self: *TreeShaker,
        mod: u32,
        infos: StmtInfos,
        sym_idx: u32,
        reachable: []?std.DynamicBitSet,
        queue: *std.ArrayListUnmanaged(BfsItem),
    ) std.mem.Allocator.Error!void {
        if (mod >= reachable.len) return;
        if (reachable[mod] == null) {
            reachable[mod] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
        }
        if (infos.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
            try self.enqueue(mod, stmt_idx, reachable, queue);
        }
        for (infos.writerStmts(sym_idx)) |writer_stmt| {
            try self.enqueue(mod, writer_stmt, reachable, queue);
        }
    }

    /// import binding을 따라 타겟 모듈의 export statement를 시드.
    fn ensureReExportNamespaceSourceMap(
        self: *TreeShaker,
        mod_idx: u32,
    ) std.mem.Allocator.Error!?*std.StringHashMapUnmanaged(u32) {
        if (mod_idx >= self.graph.moduleCount()) return null;
        if (self.re_export_namespace_sources.len == 0) {
            const maps = try self.allocator.alloc(?std.StringHashMapUnmanaged(u32), self.graph.moduleCount());
            for (maps) |*map| map.* = null;
            self.re_export_namespace_sources = maps;
        }
        if (mod_idx >= self.re_export_namespace_sources.len) return null;
        if (self.re_export_namespace_sources[mod_idx] == null) {
            var map: std.StringHashMapUnmanaged(u32) = .{};
            errdefer map.deinit(self.allocator);
            const target_module = self.getModule(mod_idx) orelse {
                self.re_export_namespace_sources[mod_idx] = map;
                return &self.re_export_namespace_sources[mod_idx].?;
            };
            for (target_module.export_bindings) |eb| {
                if (eb.kind != .re_export_namespace) continue;
                const rec_idx = eb.import_record_index orelse continue;
                if (rec_idx >= target_module.import_records.len) continue;
                const resolved = target_module.import_records[rec_idx].resolved;
                if (self.graph.getModule(resolved) == null) continue;
                const entry = try map.getOrPut(self.allocator, eb.exported_name);
                if (!entry.found_existing) entry.value_ptr.* = @intFromEnum(resolved);
            }
            self.re_export_namespace_sources[mod_idx] = map;
        }
        return &self.re_export_namespace_sources[mod_idx].?;
    }

    fn followImport(
        self: *TreeShaker,
        mod_idx: u32,
        ib_idx: u32,
        /// 이 import 참조가 발생한 dispatch stmt 인덱스. null이면 gating 적용 안 함
        /// (기존 전체 seed 동작 유지 — dynamic seed 경로 등에서 사용).
        dispatch_stmt: ?u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        var follow_scope = profile.begin(.shake_fixpoint_bfs_follow_import);
        defer follow_scope.end();

        const m = self.getModule(mod_idx) orelse return;
        if (ib_idx >= m.import_bindings.len) return;
        const ib = m.import_bindings[ib_idx];
        if (ib.import_record_index >= m.import_records.len) return;
        const rec = m.import_records[ib.import_record_index];
        if (rec.resolved.isNone()) return;
        const target = @intFromEnum(rec.resolved);
        const target_module_for_import = self.graph.getModule(rec.resolved) orelse return;

        if (ib.kind == .namespace) {
            if (target_module_for_import.wrap_kind == .cjs) {
                try self.markAndSeedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
                return;
            }
            if (ib.namespace_used_properties) |props| {
                for (props, 0..) |prop_name, pi| {
                    // per-prop stmt 정보와 dispatch_stmt가 모두 있을 때만 gating 적용.
                    // 어느 한쪽이라도 없으면 기존 전체 seed로 fallback.
                    if (dispatch_stmt) |ds| gate: {
                        const prop_stmts = ib.namespace_used_property_stmts orelse break :gate;
                        if (pi >= prop_stmts.len) break :gate;
                        if (!containsU32(prop_stmts[pi], ds)) continue;
                    }
                    try self.seedExport(target, prop_name, queue, module_stmt_infos, reachable_stmts);
                }
            } else {
                try self.markAllExportsUsed(@intCast(target));
                self.included.set(target);
                try self.seedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
            }
            return;
        }

        if (target_module_for_import.wrap_kind == .cjs and ib.kind == .default) {
            if (ib.namespace_used_properties) |props| {
                for (props, 0..) |prop_name, pi| {
                    if (dispatch_stmt) |ds| gate: {
                        const prop_stmts = ib.namespace_used_property_stmts orelse break :gate;
                        if (pi >= prop_stmts.len) break :gate;
                        if (!containsU32(prop_stmts[pi], ds)) continue;
                    }
                    try self.seedCjsExportOrAll(@intCast(target), prop_name, queue, module_stmt_infos, reachable_stmts);
                }
                return;
            }
            try self.markAndSeedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
            return;
        }

        if (target_module_for_import.wrap_kind == .cjs and ib.kind == .named) {
            try self.seedCjsExportOrAll(@intCast(target), ib.imported_name, queue, module_stmt_infos, reachable_stmts);
            return;
        }

        // #1603 Phase 1b: `.named` 바인딩이 target의 `export * as X`를 겨냥하고
        // namespace_used_properties가 populate 되어 있으면, 해당 subset을 re-export 소스 모듈에 seed.
        // 이렇게 하지 않으면 seedExport가 idx.ts의 "M"를 resolve해도 idx.ts scope에
        // "M" 로컬이 없어 enqueue가 실패 → source 모듈 statement 도달성 누락.
        if (ib.kind == .named and ib.namespace_used_properties != null) {
            const ns_source_map = try self.ensureReExportNamespaceSourceMap(@intCast(target));
            if (ns_source_map) |map| {
                if (map.get(ib.imported_name)) |inner_src| {
                    // inner_src를 include + 각 member를 seed
                    if (!self.included.isSet(inner_src)) self.included.set(inner_src);
                    for (ib.namespace_used_properties.?) |prop_name| {
                        try self.seedExport(@intCast(inner_src), prop_name, queue, module_stmt_infos, reachable_stmts);
                    }
                    // target(idx.ts)의 "M" export도 마킹 — includeReExportSources에서 tryMarkReExportNsSubset이 동작하도록.
                    try self.markExportUsed(@intCast(target), ib.imported_name);
                    return;
                }
            }
        }

        try self.seedExport(target, ib.imported_name, queue, module_stmt_infos, reachable_stmts);
    }

    /// canonical export의 선언 statement를 BFS 큐에 추가.
    fn seedExport(
        self: *TreeShaker,
        target_mod: usize,
        imported_name: []const u8,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        if (!try self.markSeedExportVisited(@intCast(target_mod), imported_name)) return;

        var seed_scope = profile.begin(.shake_fixpoint_bfs_seed_export);
        defer seed_scope.end();

        const mod_count = self.graph.moduleCount();
        const canonical = blk: {
            var resolve_scope = profile.begin(.shake_fixpoint_bfs_seed_export_resolve);
            defer resolve_scope.end();
            break :blk self.linker.resolveExportChain(@enumFromInt(@as(u32, @intCast(target_mod))), imported_name, 0) orelse return;
        };
        const canon_mod = canonical.module_index.toU32();
        const canon_m = self.graph.getModule(canonical.module_index) orelse return;

        {
            var mark_scope = profile.begin(.shake_fixpoint_bfs_seed_export_mark);
            defer mark_scope.end();

            try self.markExportUsed(canon_mod, canonical.export_name);
            self.included.set(canon_mod);
        }

        if (canon_m.wrap_kind == .cjs) {
            var cjs_scope = profile.begin(.shake_fixpoint_bfs_seed_export_cjs);
            defer cjs_scope.end();

            if (canon_mod != target_mod) {
                try self.markAndSeedAllStmts(canon_mod, queue, module_stmt_infos, reachable_stmts);
                return;
            }
            const target_infos = module_stmt_infos[canon_mod] orelse {
                try self.markAndSeedAllStmts(canon_mod, queue, module_stmt_infos, reachable_stmts);
                return;
            };
            const fact = target_infos.cjsExportFactByName(canonical.export_name) orelse {
                if (try self.seedCjsExportFactsByName(canon_mod, target_infos, canonical.export_name, queue, reachable_stmts)) {
                    return;
                }
                try self.markAndSeedAllStmts(canon_mod, queue, module_stmt_infos, reachable_stmts);
                return;
            };
            try self.seedCjsExportFact(canon_mod, target_infos, fact, queue, reachable_stmts);
            return;
        }

        // namespace barrel re-export: canonical이 namespace import를 가리키면
        // 소스 모듈의 모든 export를 시드해야 함 (import * as z; export { z } 패턴)
        var cached_canon_local: ?[]const u8 = null;
        if (canon_m.import_bindings.len > 0) {
            var namespace_scope = profile.begin(.shake_fixpoint_bfs_seed_export_namespace_scan);
            defer namespace_scope.end();

            const canon_local = self.linker.getExportLocalName(@intCast(canon_mod), canonical.export_name) orelse canonical.export_name;
            cached_canon_local = canon_local;
            for (canon_m.import_bindings) |cib| {
                if (cib.kind == .namespace and std.mem.eql(u8, cib.local_name, canon_local)) {
                    if (cib.import_record_index < canon_m.import_records.len) {
                        const ns_src_idx = canon_m.import_records[cib.import_record_index].resolved;
                        if (self.graph.getModule(ns_src_idx) != null) {
                            const ns_src = @intFromEnum(ns_src_idx);
                            try self.markAllExportsUsed(@intCast(ns_src));
                            self.included.set(ns_src);
                            try self.seedAllStmts(@intCast(ns_src), queue, module_stmt_infos, reachable_stmts);
                        }
                    }
                    break;
                }
            }
        }

        if (canon_mod != target_mod and target_mod < mod_count) {
            var intermediate_scope = profile.begin(.shake_fixpoint_bfs_seed_export_intermediate);
            defer intermediate_scope.end();

            try self.markExportUsed(@intCast(target_mod), imported_name);
            self.included.set(target_mod);
            // 중간 모듈의 export 선언 statement도 reachable로 마킹
            const mid_module = self.getModule(@intCast(target_mod)).?.*;
            if (mid_module.semantic) |mid_sem| {
                if (mid_sem.scope_maps.len > 0) {
                    const mid_local = self.linker.getExportLocalName(@intCast(target_mod), imported_name) orelse imported_name;
                    if (mid_sem.scope_maps[0].get(mid_local)) |mid_sym| {
                        if (module_stmt_infos[target_mod]) |mid_infos| {
                            try self.enqueueSymbolLiveStatements(@intCast(target_mod), mid_infos, @intCast(mid_sym), reachable_stmts, queue);
                        }
                    }
                }
            }
        }

        const target_module = canon_m;
        var semantic_scope = profile.begin(.shake_fixpoint_bfs_seed_export_semantic_lookup);
        const target_sem = target_module.semantic orelse {
            semantic_scope.end();
            var opaque_scope = profile.begin(.shake_fixpoint_bfs_seed_export_opaque);
            defer opaque_scope.end();
            try self.seedOpaqueModule(@intCast(canon_mod), queue, module_stmt_infos, reachable_stmts);
            return;
        };
        if (target_sem.scope_maps.len == 0) {
            semantic_scope.end();
            return;
        }

        const sym_idx = if (target_module.findExportSymbol(canonical.export_name).semanticIndex()) |direct_sym|
            direct_sym
        else blk: {
            const local_name = cached_canon_local orelse (self.linker.getExportLocalName(@intCast(canon_mod), canonical.export_name) orelse canonical.export_name);
            break :blk target_sem.scope_maps[0].get(local_name) orelse {
                semantic_scope.end();
                return;
            };
        };
        const target_infos = module_stmt_infos[canon_mod] orelse {
            semantic_scope.end();
            var opaque_scope = profile.begin(.shake_fixpoint_bfs_seed_export_opaque);
            defer opaque_scope.end();
            try self.seedOpaqueModule(@intCast(canon_mod), queue, module_stmt_infos, reachable_stmts);
            return;
        };
        semantic_scope.end();

        {
            var enqueue_scope = profile.begin(.shake_fixpoint_bfs_seed_export_enqueue_symbol);
            defer enqueue_scope.end();

            try self.enqueueSymbolLiveStatements(@intCast(canon_mod), target_infos, @intCast(sym_idx), reachable_stmts, queue);
        }

        // side-effect statement는 enqueueStmt에서 lazy 시드됨
    }

    fn seedCjsExportOrAll(
        self: *TreeShaker,
        mod_idx: u32,
        export_name: []const u8,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        try self.markExportUsed(mod_idx, export_name);
        self.included.set(mod_idx);
        const infos = if (mod_idx < module_stmt_infos.len) module_stmt_infos[mod_idx] else null;
        const target_infos = infos orelse {
            try self.markAndSeedAllStmts(mod_idx, queue, module_stmt_infos, reachable_stmts);
            return;
        };
        const fact = target_infos.cjsExportFactByName(export_name) orelse {
            if (try self.seedNodeBufferModuleObjectExport(mod_idx, export_name, target_infos, queue, reachable_stmts)) {
                return;
            }
            if (try self.seedCjsModuleExportsRequireProxy(mod_idx, export_name, target_infos, queue, module_stmt_infos, reachable_stmts)) {
                return;
            }
            if (try self.seedCjsExportFactsByName(mod_idx, target_infos, export_name, queue, reachable_stmts)) {
                return;
            }
            try self.markAndSeedAllStmts(mod_idx, queue, module_stmt_infos, reachable_stmts);
            return;
        };
        try self.seedCjsExportFact(mod_idx, target_infos, fact, queue, reachable_stmts);
    }

    fn seedNodeBufferModuleObjectExport(
        self: *TreeShaker,
        mod_idx: u32,
        export_name: []const u8,
        infos: StmtInfos,
        queue: *std.ArrayListUnmanaged(BfsItem),
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!bool {
        if (self.graph.resolve_cache.platform != .node) return false;
        if (!std.mem.eql(u8, export_name, "Buffer")) return false;
        const m = self.getModule(mod_idx) orelse return false;
        const ast = &(m.ast orelse return false);

        var buffer_names: std.StringHashMapUnmanaged(void) = .{};
        defer buffer_names.deinit(self.allocator);
        collectNodeBufferModuleObjectNames(self.allocator, ast, &buffer_names) catch return false;
        if (buffer_names.count() == 0) return false;

        for (infos.stmts, 0..) |stmt, si| {
            const stmt_ni: usize = stmt.node_idx;
            if (stmt_ni >= ast.nodes.items.len) continue;
            if (!isModuleExportsAssignedNodeBufferObject(ast, ast.nodes.items[stmt_ni], &buffer_names)) continue;
            if (reachable_stmts[mod_idx] == null) {
                reachable_stmts[mod_idx] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
            }
            try self.enqueue(mod_idx, @intCast(si), reachable_stmts, queue);
            return true;
        }
        return false;
    }

    fn seedCjsModuleExportsRequireProxy(
        self: *TreeShaker,
        mod_idx: u32,
        export_name: []const u8,
        infos: StmtInfos,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!bool {
        const m = self.getModule(mod_idx) orelse return false;
        const ast = &(m.ast orelse return false);

        for (infos.stmts, 0..) |stmt, si| {
            const stmt_ni: usize = stmt.node_idx;
            if (stmt_ni >= ast.nodes.items.len) continue;
            const target = moduleExportsRequireTargetAt(m, ast, @enumFromInt(stmt_ni)) orelse continue;
            const target_idx: u32 = @intFromEnum(target);
            if (target_idx == mod_idx) continue;

            if (reachable_stmts[mod_idx] == null) {
                reachable_stmts[mod_idx] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
            }
            try self.enqueue(mod_idx, @intCast(si), reachable_stmts, queue);
            try self.seedCjsExportOrAll(target_idx, export_name, queue, module_stmt_infos, reachable_stmts);
            return true;
        }
        return false;
    }

    fn seedCjsExportFactsByName(
        self: *TreeShaker,
        mod_idx: u32,
        infos: StmtInfos,
        export_name: []const u8,
        queue: *std.ArrayListUnmanaged(BfsItem),
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!bool {
        var found = false;
        for (infos.cjs_export_facts) |fact| {
            if (!std.mem.eql(u8, fact.export_name, export_name)) continue;
            found = true;
            try self.seedCjsExportFact(mod_idx, infos, fact, queue, reachable_stmts);
        }
        return found;
    }

    fn seedCjsExportFact(
        self: *TreeShaker,
        mod_idx: u32,
        infos: StmtInfos,
        fact: stmt_info_mod.CjsExportFact,
        queue: *std.ArrayListUnmanaged(BfsItem),
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        if (reachable_stmts[mod_idx] == null) {
            reachable_stmts[mod_idx] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
        }

        if (fact.kind.seedsWholeStatement()) {
            try self.enqueue(mod_idx, fact.statement_index, reachable_stmts, queue);
            return;
        }

        if (fact.statement_index < infos.stmts.len) {
            reachable_stmts[mod_idx].?.set(fact.statement_index);
        }

        const rhs_sym = fact.rhs_symbol orelse return;
        if (infos.declaredStmtBySymbol(rhs_sym)) |dep_stmt| {
            try self.enqueue(mod_idx, dep_stmt, reachable_stmts, queue);
        }
        for (infos.writerStmts(rhs_sym)) |writer_stmt| {
            try self.enqueue(mod_idx, writer_stmt, reachable_stmts, queue);
        }
    }

    /// StmtInfo 없는 모듈 (entry, CJS 등)의 import를 BFS로 전파.
    fn seedOpaqueModule(
        self: *TreeShaker,
        mod_idx: u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        const m = self.getModule(mod_idx) orelse return;
        if (self.opaque_visited) |ov| {
            if (ov.isSet(mod_idx)) return;
        }
        if (self.opaque_visited) |*ov| ov.set(mod_idx);

        for (m.import_bindings) |ib| {
            // StmtInfo/reachability가 있으면 dead statement의 import는 배제.
            // 없으면(wrapped 등) 보수적으로 모두 시드 — 모듈 전체 포함되는 경로.
            if (mod_idx < self.reachable_stmts.len and self.reachable_stmts[mod_idx] != null) {
                if (!self.isImportLiveInModule(mod_idx, ib.local_name)) continue;
            }
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target = @intFromEnum(rec.resolved);
            if (self.graph.getModule(rec.resolved) == null) continue;

            if (ib.kind == .namespace) {
                if (ib.namespace_used_properties) |props| {
                    for (props) |p| try self.seedExport(target, p, queue, module_stmt_infos, reachable_stmts);
                } else {
                    try self.markAllExportsUsed(@intCast(target));
                    self.included.set(target);
                    try self.seedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
                }
            } else {
                if (ib.kind == .named and ib.namespace_used_properties != null) {
                    const ns_source_map = try self.ensureReExportNamespaceSourceMap(@intCast(target));
                    if (ns_source_map) |map| {
                        if (map.get(ib.imported_name)) |inner_src| {
                            if (!self.included.isSet(target)) self.included.set(target);
                            if (!self.included.isSet(inner_src)) self.included.set(inner_src);
                            for (ib.namespace_used_properties.?) |prop_name| {
                                try self.seedExport(@intCast(inner_src), prop_name, queue, module_stmt_infos, reachable_stmts);
                            }
                            try self.markExportUsed(@intCast(target), ib.imported_name);
                            continue;
                        }
                    }
                }
                try self.seedExport(target, ib.imported_name, queue, module_stmt_infos, reachable_stmts);
            }
        }
        // re-export 처리
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export and !eb.kind.isReExportAll()) continue;
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const src_idx = m.import_records[rec_idx].resolved;
                    if (self.graph.getModule(src_idx) == null) continue;
                    const src = @intFromEnum(src_idx);
                    if (eb.kind == .re_export_star) {
                        if (self.isExportUsed(mod_idx, ALL_EXPORTS_SENTINEL)) {
                            try self.markAndSeedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
                        } else {
                            try self.seedUsedReExportStarNames(mod_idx, @intCast(src), queue, module_stmt_infos, reachable_stmts);
                        }
                    } else if (eb.kind.isReExportAll()) {
                        // `export * as ns from` (re_export_namespace): namespace 객체 자체가 named export
                        // 라 소비자가 `ns.foo` 로 escape 가능 → 정밀화 불가, 보수적으로 markAll.
                        try self.markAndSeedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
                    } else {
                        try self.seedExport(src, m.exportBindingLocalName(eb), queue, module_stmt_infos, reachable_stmts);
                    }
                }
            }
        }
    }

    /// 모듈의 모든 statement를 BFS 큐에 추가.
    /// export * / export { x } from 're-export 대상 모듈도 재귀적으로 시드한다.
    /// (namespace escape 등으로 모듈 전체가 live인 경우, re-export 체인의
    ///  하위 모듈 statement도 reachable이어야 DCE에서 살아남는다.)
    fn seedAllStmts(
        self: *TreeShaker,
        mod_idx: u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        if (mod_idx >= module_stmt_infos.len) return;
        // 순환 export * 방지: opaque_visited로 이미 처리한 모듈 skip
        if (self.opaque_visited) |ov| {
            if (ov.isSet(mod_idx)) return;
        }
        if (self.opaque_visited) |*ov| ov.set(mod_idx);

        const infos = module_stmt_infos[mod_idx] orelse return;
        if (reachable_stmts[mod_idx] == null) {
            reachable_stmts[mod_idx] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
        }
        for (infos.stmts, 0..) |_, si| {
            try self.enqueue(mod_idx, @intCast(si), reachable_stmts, queue);
        }

        // re-export 체인 전파: export * / named re-export 대상 모듈도 시드.
        const m = self.getModule(mod_idx) orelse return;
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export and !eb.kind.isReExportAll()) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= m.import_records.len) continue;
            const src_idx = m.import_records[rec_idx].resolved;
            if (self.graph.getModule(src_idx) == null) continue;
            const src = @intFromEnum(src_idx);
            if (eb.kind == .re_export_star) {
                if (self.isExportUsed(mod_idx, ALL_EXPORTS_SENTINEL)) {
                    self.included.set(src);
                    try self.seedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
                } else {
                    try self.seedUsedReExportStarNames(mod_idx, @intCast(src), queue, module_stmt_infos, reachable_stmts);
                }
            } else if (eb.kind.isReExportAll()) {
                // re_export_namespace: namespace 객체 escape 가능 — 정밀화 불가.
                // 호출자(seedAllStmts 진입자)가 markAll 처리했다고 가정하므로 여기선 included+seed 만.
                self.included.set(src);
                try self.seedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
            } else {
                try self.seedExport(src, m.exportBindingLocalName(eb), queue, module_stmt_infos, reachable_stmts);
            }
        }
        // namespace import 전파: import * as X에서 X가 사용되면 소스 모듈도 시드
        for (m.import_bindings) |ib| {
            if (ib.kind != .namespace) continue;
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target = @intFromEnum(rec.resolved);
            if (self.graph.getModule(rec.resolved) == null) continue;
            self.included.set(target);
            try self.seedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
        }
        // module.exports = require("./impl") proxy 전파: 호출자가 mod_idx 전체를 live 로
        // 본 이상 proxy target 도 fully include. opaque_visited 로 재진입 방어.
        try self.seedModuleExportsRequireProxyTargetsAll(mod_idx, queue, module_stmt_infos, reachable_stmts);
    }

    fn seedSideEffectStmts(
        self: *TreeShaker,
        mod_idx: u32,
        infos: StmtInfos,
        queue: *std.ArrayListUnmanaged(BfsItem),
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        self.included.set(mod_idx);
        if (reachable_stmts[mod_idx] == null) {
            reachable_stmts[mod_idx] = try std.DynamicBitSet.initEmpty(self.allocator, infos.stmts.len);
        }
        for (infos.stmts, 0..) |stmt, si| {
            if (!stmt.has_side_effects) continue;
            try self.enqueue(mod_idx, @intCast(si), reachable_stmts, queue);
        }
    }

    fn markAndSeedAllStmts(
        self: *TreeShaker,
        mod_idx: u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        try self.markAllExportsUsed(mod_idx);
        self.included.set(mod_idx);
        try self.seedAllStmts(mod_idx, queue, module_stmt_infos, reachable_stmts);
    }

    fn seedModuleExportsRequireProxyTargetsAll(
        self: *TreeShaker,
        mod_idx: u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        const m = self.getModule(mod_idx) orelse return;
        const infos = if (mod_idx < module_stmt_infos.len) module_stmt_infos[mod_idx] else null;
        const target_infos = infos orelse return;
        const ast = &(m.ast orelse return);
        for (target_infos.stmts) |stmt| {
            const stmt_ni = stmt.node_idx;
            if (stmt_ni >= ast.nodes.items.len) continue;
            const target = moduleExportsRequireTargetAt(m, ast, @enumFromInt(stmt_ni)) orelse continue;
            const target_idx: u32 = @intFromEnum(target);
            if (target_idx == mod_idx) continue;
            if (self.isExportUsed(target_idx, ALL_EXPORTS_SENTINEL)) continue;
            try self.markAndSeedAllStmts(target_idx, queue, module_stmt_infos, reachable_stmts);
        }
    }

    fn collectDirectUsedExportNames(self: *TreeShaker, module_index: u32) !std.ArrayListUnmanaged([]const u8) {
        var names: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer names.deinit(self.allocator);

        // used_exports 키 형식 (types.makeModuleKey, types.zig:716): [u32 module_idx][0x00][name]
        var it = self.used_exports.keyIterator();
        while (it.next()) |key_ptr| {
            const key = key_ptr.*;
            if (key.len < 5 or key[4] != 0) continue;
            var key_module: u32 = undefined;
            @memcpy(std.mem.asBytes(&key_module), key[0..4]);
            if (key_module != module_index) continue;

            const name = key[5..];
            if (std.mem.eql(u8, name, ALL_EXPORTS_SENTINEL)) continue;
            try names.append(self.allocator, name);
        }
        return names;
    }

    fn seedUsedReExportStarNames(
        self: *TreeShaker,
        reexport_mod: u32,
        src_mod: u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        var names = try self.collectDirectUsedExportNames(reexport_mod);
        defer names.deinit(self.allocator);
        if (names.items.len == 0) return;

        const reexport_idx: ModuleIndex = @enumFromInt(reexport_mod);
        const src_idx: ModuleIndex = @enumFromInt(src_mod);
        if (self.getModule(src_mod)) |src_module| {
            if (src_module.wrap_kind == .cjs) {
                try self.markAndSeedAllStmts(src_mod, queue, module_stmt_infos, reachable_stmts);
                return;
            }
        }
        for (names.items) |name| {
            const from_reexport = self.linker.resolveExportChain(reexport_idx, name, 0) orelse continue;
            const from_src = self.linker.resolveExportChain(src_idx, name, 0) orelse {
                const src_module = self.getModule(src_mod) orelse continue;
                if (from_reexport.module_index.toU32() == src_mod and
                    (src_module.wrap_kind.isWrapped() or src_module.exports_kind == .esm_with_dynamic_fallback))
                {
                    try self.markAndSeedAllStmts(src_mod, queue, module_stmt_infos, reachable_stmts);
                }
                continue;
            };
            if (from_reexport.module_index != from_src.module_index) continue;
            if (!std.mem.eql(u8, from_reexport.export_name, from_src.export_name)) continue;
            try self.seedExport(src_mod, name, queue, module_stmt_infos, reachable_stmts);
        }
    }

    fn includeReExportSources(self: *TreeShaker, check_used: bool) !bool {
        var scope = profile.begin(.shake_fixpoint_re_exports);
        defer scope.end();

        var changed = false;
        for (0..self.graph.moduleCount()) |i| {
            if (!self.included.isSet(i)) continue;
            const m = self.getModule(@intCast(i)) orelse continue;
            var ns_usage: ReExportNsConsumerUsage = .{};
            var ns_usage_built = false;
            defer ns_usage.deinit(self.allocator);
            for (m.export_bindings) |eb| {
                if (eb.kind != .re_export and !eb.kind.isReExportAll()) continue;
                const rec_idx = eb.import_record_index orelse continue;
                if (rec_idx >= m.import_records.len) continue;
                const src_idx = m.import_records[rec_idx].resolved;
                const src_module = self.graph.getModule(src_idx) orelse continue;
                const src = @intFromEnum(src_idx);
                // 평가 부수효과가 없는 source 는 사용된 export 가 있을 때만 끌어옴.
                // `export *` 의 named import 는 seedExport 가 canonical source 로 직접 시드하므로,
                // 전체 namespace 가 사용되지 않는 한 unrelated star source 까지 fan out 하지 않는다.
                if (check_used and !moduleHasEvaluationEffect(src_module)) {
                    const probe_name = if (eb.kind == .re_export_star) ALL_EXPORTS_SENTINEL else eb.exported_name;
                    if (!self.isExportUsed(@intCast(i), probe_name)) continue;
                }
                if (!self.included.isSet(src)) {
                    self.included.set(src);
                    changed = true;
                }
                if (src_module.wrap_kind == .cjs and eb.kind == .re_export_star) {
                    try self.markAllExportsUsed(@intCast(src));
                } else if (eb.kind == .re_export_namespace) {
                    // #1603 Phase 1b: 모든 소비자의 `namespace_used_properties`를
                    // 집계해 subset이 결정 가능하면 해당 member만 used로 마킹.
                    // 하나라도 opaque(null)이면 전체 사용 fallback.
                    if (!ns_usage_built) {
                        try self.collectReExportNsConsumerUsage(@intCast(i), &ns_usage);
                        ns_usage_built = true;
                    }
                    if (try self.tryMarkReExportNsSubset(@intCast(i), eb.exported_name, @intCast(src), &ns_usage)) continue;
                    try self.markAllExportsUsed(@intCast(src));
                } else if (!check_used) {
                    try self.markAllExportsUsed(@intCast(src));
                }
            }
        }
        return changed;
    }

    /// included 모듈의 import_record 가 source 모듈을 evaluation 의존으로 끌어와야 하는지.
    /// re-export 는 target 이 evaluation effect 를 갖거나 (side_effects/wrapped/dynamic-fallback),
    /// 해당 stmt 가 reachable 일 때만 보존 — `export *` 가 unrelated source 까지 fan out 하지 않도록.
    /// side_effect / require / worker / glob / require_context 는 항상 evaluation 의존이라 보존.
    /// static_import 만 entry 또는 live binding 이 있을 때만 보존 — dead body 안에서만 참조되는
    /// named import 가 source 모듈을 fan out 시키지 않도록. dynamic_import 는 별도
    /// dyn_import_targets 경로로 처리되므로 여기선 false.
    fn shouldPreserveImportRecordForEvaluation(
        self: *TreeShaker,
        m: *const Module,
        mod_idx: u32,
        rec_idx: u32,
        live_mod_idx: ?u32,
    ) !bool {
        if (rec_idx >= m.import_records.len) return false;
        if (m.import_records[rec_idx].kind == .re_export) {
            if (self.graph.getModule(m.import_records[rec_idx].resolved)) |target| {
                if (moduleHasEvaluationEffect(target)) return true;
            }
            return try self.importRecordHasReachableStmt(mod_idx, rec_idx);
        }
        if (live_mod_idx == null) return true;
        return switch (m.import_records[rec_idx].kind) {
            .dynamic_import => false,
            .require => try self.importRecordHasReachableStmt(live_mod_idx.?, rec_idx),
            .static_import => self.entry_set.isSet(mod_idx) or self.importRecordHasLiveBinding(m, mod_idx, rec_idx),
            else => true,
        };
    }

    fn importRecordHasReachableStmt(self: *TreeShaker, mod_idx: u32, rec_idx: u32) !bool {
        if (mod_idx >= self.module_stmt_infos.len or mod_idx >= self.reachable_stmts.len) return true;
        const infos = self.module_stmt_infos[mod_idx] orelse return true;
        const reachable = self.reachable_stmts[mod_idx] orelse return false;
        const stmt_indices = (try self.ensureImportRecordStmtIndices(mod_idx, infos)) orelse return false;
        if (rec_idx >= stmt_indices.len) return false;
        const stmt_idx = stmt_indices[rec_idx] orelse return false;
        return reachable.isSet(stmt_idx);
    }

    fn importRecordBelongsToStmt(self: *TreeShaker, mod_idx: u32, infos: StmtInfos, stmt_idx: u32, rec_idx: u32) !bool {
        if (stmt_idx >= infos.stmts.len) return false;
        const stmt_indices = (try self.ensureImportRecordStmtIndices(mod_idx, infos)) orelse return false;
        if (rec_idx >= stmt_indices.len) return false;
        return stmt_indices[rec_idx] == stmt_idx;
    }

    fn ensureImportRecordStmtIndices(self: *TreeShaker, mod_idx: u32, infos: StmtInfos) !?[]?u32 {
        const mod_count = self.graph.moduleCount();
        if (mod_idx >= mod_count) return null;
        if (self.import_record_stmt_indices.len == 0) {
            const maps = try self.allocator.alloc(?[]?u32, mod_count);
            for (maps) |*m| m.* = null;
            self.import_record_stmt_indices = maps;
        }
        if (mod_idx >= self.import_record_stmt_indices.len) return null;
        if (self.import_record_stmt_indices[mod_idx] == null) {
            const m = self.getModule(mod_idx) orelse return null;
            const map = try self.allocator.alloc(?u32, m.import_records.len);
            errdefer self.allocator.free(map);
            for (map) |*slot| slot.* = null;
            for (m.import_records, 0..) |rec, rec_i| {
                map[rec_i] = stmtIndexForPos(infos, rec.span.start);
            }
            self.import_record_stmt_indices[mod_idx] = map;
        }
        return self.import_record_stmt_indices[mod_idx].?;
    }

    fn stmtIndexForPos(infos: StmtInfos, pos: u32) ?u32 {
        var lo: usize = 0;
        var hi: usize = infos.stmts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const span = infos.stmts[mid].span;
            if (pos < span.start) {
                hi = mid;
            } else if (pos >= span.end) {
                lo = mid + 1;
            } else {
                return @intCast(mid);
            }
        }
        return null;
    }

    test "stmtIndexForPos maps import record spans to containing top-level statement" {
        const StmtInfo = stmt_info_mod.StmtInfo;
        var stmts = [_]StmtInfo{
            .{
                .node_idx = 0,
                .span = .{ .start = 0, .end = 10 },
                .has_side_effects = false,
                .declared_symbols = &.{},
                .referenced_symbols = &.{},
            },
            .{
                .node_idx = 1,
                .span = .{ .start = 20, .end = 40 },
                .has_side_effects = false,
                .declared_symbols = &.{},
                .referenced_symbols = &.{},
            },
            .{
                .node_idx = 2,
                .span = .{ .start = 50, .end = 70 },
                .has_side_effects = false,
                .declared_symbols = &.{},
                .referenced_symbols = &.{},
            },
        };
        const infos = StmtInfos{
            .stmts = &stmts,
            .symbol_to_stmt = &.{},
            .sym_to_side_effect_stmts = &.{},
            .sym_to_referencing_stmts = &.{},
            .sym_to_writer_stmts = &.{},
            .allocator = std.testing.allocator,
        };

        try std.testing.expectEqual(@as(?u32, 0), stmtIndexForPos(infos, 0));
        try std.testing.expectEqual(@as(?u32, 0), stmtIndexForPos(infos, 9));
        try std.testing.expectEqual(@as(?u32, 1), stmtIndexForPos(infos, 20));
        try std.testing.expectEqual(@as(?u32, 1), stmtIndexForPos(infos, 39));
        try std.testing.expectEqual(@as(?u32, 2), stmtIndexForPos(infos, 50));
        try std.testing.expectEqual(@as(?u32, null), stmtIndexForPos(infos, 10));
        try std.testing.expectEqual(@as(?u32, null), stmtIndexForPos(infos, 45));
        try std.testing.expectEqual(@as(?u32, null), stmtIndexForPos(infos, 70));
    }

    /// `isImportLiveInModule` 은 reachable_stmts 미초기화 시 보수적으로 true 를 반환하지만,
    /// 이 함수는 "stmt_info 는 빌드됐는데 reachable_stmts 가 비었다 = BFS 가 한 번도 방문 안
    /// 한 모듈" 이라 판단해 false 로 정밀화한다. shouldPreserveImportRecordForEvaluation 의
    /// static_import 케이스에서만 호출되며, fan-out 보수성을 의도적으로 줄인다.
    fn importRecordHasLiveBinding(self: *const TreeShaker, m: *const Module, mod_idx: u32, rec_idx: u32) bool {
        if (mod_idx < self.module_stmt_infos.len and self.module_stmt_infos[mod_idx] != null) {
            if (mod_idx >= self.reachable_stmts.len or self.reachable_stmts[mod_idx] == null) return false;
        }
        for (m.import_bindings) |ib| {
            if (ib.import_record_index != rec_idx) continue;
            if (self.isImportLiveInModule(mod_idx, ib.local_name)) return true;
        }
        return false;
    }

    /// #1603 Phase 1b: `export * as X from './src'` 재export에 대해 모든 소비자의 member 접근
    /// 집합을 집계. 반환값 `true`: precision 성공(또는 소비자 0명 — markAll 불필요).
    /// `false`: 적어도 한 소비자가 opaque → 호출자가 전체 fallback 적용.
    fn collectReExportNsConsumerUsage(
        self: *TreeShaker,
        reexport_mod: u32,
        usage: *ReExportNsConsumerUsage,
    ) !void {
        const reexporter = self.getModule(reexport_mod) orelse return;
        for (reexporter.importers.items) |consumer_idx| {
            const consumer = self.getModule(@intFromEnum(consumer_idx)) orelse continue;
            for (consumer.import_bindings) |ib| {
                if (ib.import_record_index >= consumer.import_records.len) continue;
                const resolved = consumer.import_records[ib.import_record_index].resolved;
                if (resolved == .none or @intFromEnum(resolved) != reexport_mod) continue;

                switch (ib.kind) {
                    .named => {
                        const props = ib.namespace_used_properties orelse {
                            try usage.markOpaque(self.allocator, ib.imported_name);
                            continue;
                        };
                        try usage.addProps(self.allocator, ib.imported_name, props);
                    },
                    .namespace => {
                        const props = ib.namespace_used_properties orelse {
                            usage.opaque_all = true;
                            continue;
                        };
                        // `import * as Lib from './barrel'; Lib.NsA` only proves that
                        // NsA itself is used. Member depth inside NsA is opaque, so the
                        // matching re-export namespace must fall back to markAll.
                        for (props) |prop| try usage.markOpaque(self.allocator, prop);
                    },
                    .default => {},
                }
            }
        }
    }

    fn tryMarkReExportNsSubset(
        self: *TreeShaker,
        reexport_mod: u32,
        reexport_name: []const u8,
        src_mod: u32,
        usage: *ReExportNsConsumerUsage,
    ) !bool {
        // Chain check: reexport_mod 가 다른 모듈의 `export * from` source 면 transitive
        // consumer 가 reexport_name 을 사용할 수 있다. chain 너머의 namespace_used_properties
        // 는 추적 안 하므로 보수적으로 fallback — markAllExportsUsed (#1928).
        if (self.re_export_star_targets) |mask| {
            if (mask.isSet(reexport_mod)) return false;
        }

        if (usage.opaque_all) return false;
        const entry = usage.entries.getPtr(reexport_name) orelse return true;
        if (entry.is_opaque) return false;

        // union에 포함된 member만 source 모듈에서 used로 마킹.
        // 소비자 0명이면 entry가 없어 아무것도 마킹 안 함 — precision 성공으로 취급(markAll 불필요).
        var kit = entry.props.keyIterator();
        while (kit.next()) |key| {
            try self.markExportUsed(src_mod, key.*);
        }
        return true;
    }

    /// import binding → export 마킹 + canonical 모듈 포함.
    /// live_mod_idx가 non-null이면 StmtInfo 도달성 기반 추가 필터링 적용.
    fn processModuleImportsInner(self: *TreeShaker, m: Module, live_mod_idx: ?u32) !bool {
        var scope = profile.begin(.shake_fixpoint_process_imports);
        defer scope.end();

        // moduleHasAnyReachableStmt 는 binding 루프 내내 결과 불변 — 한 번만 검사 후
        // 도달 stmt 0 이면 어떤 binding 도 live 일 수 없으므로 즉시 종료.
        if (live_mod_idx) |idx| {
            if (!self.moduleHasAnyReachableStmt(idx)) return false;
        }
        var newly_included = false;
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target_mod = @intFromEnum(rec.resolved);
            const target_module = self.graph.getModule(rec.resolved) orelse continue;

            if (live_mod_idx) |idx| {
                // Transformer 가 graph parse 단계에서 inject 한 runtime helper import 는
                // semantic 의 scope_maps 에 등록되지 않아 isImportLiveInModule 가 항상
                // false 를 반환 — cjs-wrap 모듈에서 이 분기에 걸리면 helper module 이
                // included 되지 못하고 dist preamble 에서 사라진다 (`__read is not defined`).
                // helper 는 transformer 가 명시 inject 한 것이므로 무조건 live 로 처리.
                const is_runtime_helper = runtime_helper_modules.isVirtualId(target_module.path);
                if (!is_runtime_helper and !self.isImportLiveInModule(idx, ib.local_name)) continue;
            }

            if (target_module.wrap_kind == .cjs) {
                if (ib.kind == .default) {
                    if (ib.namespace_used_properties) |props| {
                        for (props) |prop_name| {
                            try self.markExportUsed(@intCast(target_mod), prop_name);
                        }
                    } else {
                        try self.markAllExportsUsed(@intCast(target_mod));
                    }
                } else if (ib.kind == .namespace) {
                    try self.markAllExportsUsed(@intCast(target_mod));
                } else {
                    try self.markExportUsed(@intCast(target_mod), ib.imported_name);
                }
                if (!self.included.isSet(target_mod)) {
                    self.included.set(target_mod);
                    newly_included = true;
                }
                continue;
            }

            const canonical = self.linker.resolveExportChain(rec.resolved, ib.imported_name, 0);
            if (canonical) |c| {
                const canon_idx = c.module_index.toU32();
                if (self.graph.getModule(c.module_index) != null) {
                    try self.markExportUsed(canon_idx, c.export_name);
                    if (!self.included.isSet(canon_idx)) {
                        self.included.set(canon_idx);
                        newly_included = true;
                    }
                }
                if (canon_idx != target_mod) {
                    try self.markExportUsed(@intCast(target_mod), ib.imported_name);
                    if (!self.included.isSet(target_mod)) {
                        self.included.set(target_mod);
                        newly_included = true;
                    }
                }
            } else if (ib.kind == .namespace) {
                // namespace import: namespace_used_properties가 있으면 해당 prop만, 없으면
                // 전체 모듈을 "*" sentinel로 표시(BFS가 seedAllStmts로 전체 시드).
                // #1559에서 무조건 markAllExportsUsed했던 것을 #1558 Step 4에서 되돌려
                // 정밀도 복원 — BFS가 live statement 내의 namespace access만 따라간다.
                if (ib.namespace_used_properties) |props| {
                    for (props) |prop_name| {
                        if (self.linker.resolveExportChain(rec.resolved, prop_name, 0)) |c| {
                            const canon_idx = c.module_index.toU32();
                            if (self.graph.getModule(c.module_index) != null) {
                                try self.markExportUsed(canon_idx, c.export_name);
                                if (!self.included.isSet(canon_idx)) {
                                    self.included.set(canon_idx);
                                    newly_included = true;
                                }
                            }
                        }
                    }
                }
            }
        }
        return newly_included;
    }

    fn markExportUsed(self: *TreeShaker, module_index: u32, export_name: []const u8) !void {
        var key_buf: [4096]u8 = undefined;
        const lookup_key = types.makeModuleKeyBuf(&key_buf, module_index, export_name);
        if (self.used_exports.contains(lookup_key)) return;

        const key = try types.makeModuleKey(self.allocator, module_index, export_name);
        try self.used_exports.put(key, {});

        // O(1) per-module used export 플래그 갱신
        if (module_index < self.has_direct_used_export.len) {
            self.has_direct_used_export[module_index] = true;
        }
    }

    fn applyNodeBufferCapabilityFacts(self: *TreeShaker) !void {
        const mod_count = self.graph.moduleCount();
        for (0..mod_count) |i| {
            const m = self.moduleAtMut(@intCast(i)) orelse continue;
            if (m.wrap_kind != .cjs) continue;
            const ast = &(m.ast orelse continue);
            if (!foldNodeBufferCapabilityIfs(self.allocator, ast)) continue;
            self.markAstMutatedAndResync(m);
        }
    }

    fn moduleHasAnyReachableStmt(self: *const TreeShaker, module_index: u32) bool {
        if (module_index >= self.reachable_stmts.len) return true;
        const reachable = self.reachable_stmts[module_index] orelse return false;
        return reachable.count() > 0;
    }

    fn markAllExportsUsed(self: *TreeShaker, module_index: u32) !void {
        const m = self.getModule(module_index) orelse return;
        // 순환 export * 방지: 이미 처리한 모듈은 skip
        if (self.isExportUsed(module_index, ALL_EXPORTS_SENTINEL)) return;
        try self.markExportUsed(module_index, ALL_EXPORTS_SENTINEL);
        for (m.export_bindings) |eb| {
            // re-export 소스 include는 sentinel skip 전에 처리
            if (eb.kind.isReExportAll() or eb.kind == .re_export) {
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const source_idx = m.import_records[rec_idx].resolved;
                        if (self.graph.getModule(source_idx) != null) {
                            const source_mod = @intFromEnum(source_idx);
                            if (!self.included.isSet(source_mod)) self.included.set(source_mod);
                            if (eb.kind.isReExportAll()) {
                                try self.markAllExportsUsed(@intCast(source_mod));
                            } else {
                                // named re-export: canonical 모듈도 include
                                if (self.linker.resolveExportChain(
                                    source_idx,
                                    m.exportBindingLocalName(eb),
                                    0,
                                )) |canonical| {
                                    const canon_idx = canonical.module_index.toU32();
                                    if (self.graph.getModule(canonical.module_index) != null) {
                                        if (!self.included.isSet(canon_idx)) self.included.set(canon_idx);
                                        try self.markExportUsed(canon_idx, canonical.export_name);
                                    }
                                }
                            }
                        }
                    }
                }
                if (eb.kind.isReExportAll()) continue;
            }
            if (std.mem.eql(u8, eb.exported_name, "*")) continue;

            try self.markExportUsed(module_index, eb.exported_name);
        }
    }

    fn hasAnyUsedExport(self: *const TreeShaker, module_index: u32) bool {
        const m = self.getModule(module_index) orelse return false;
        for (m.export_bindings) |eb| {
            if (eb.kind.isReExportAll()) continue;
            if (std.mem.eql(u8, eb.exported_name, "*")) continue;
            if (self.isExportUsed(module_index, eb.exported_name)) return true;
        }
        return false;
    }

    /// 이 모듈에 used export가 하나라도 있는지 O(1)로 확인.
    /// markExportUsed에서 설정한 per-module boolean 배열을 조회한다.
    /// re_export_all만 있는 barrel 모듈도 canonical resolution으로 마킹된 경우 보호한다.
    fn hasAnyUsedExportDirect(self: *const TreeShaker, module_index: u32) bool {
        if (module_index < self.has_direct_used_export.len) {
            return self.has_direct_used_export[module_index];
        }
        return false;
    }
};

fn containsU32(slice: []const u32, target: u32) bool {
    for (slice) |v| if (v == target) return true;
    return false;
}

fn foldNodeBufferCapabilityIfs(allocator: std.mem.Allocator, ast: *Ast) bool {
    var buffer_names: std.StringHashMapUnmanaged(void) = .{};
    defer buffer_names.deinit(allocator);
    collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names) catch return false;
    if (buffer_names.count() == 0) return false;

    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .{};
    defer buffer_ctor_names.deinit(allocator);
    collectNodeBufferCtorNames(allocator, ast, &buffer_names, &buffer_ctor_names) catch return false;
    if (buffer_ctor_names.count() == 0) return false;

    var dead_fallback_names: std.StringHashMapUnmanaged(void) = .{};
    defer dead_fallback_names.deinit(allocator);

    var changed = false;
    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .if_statement) continue;
        var caps: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &buffer_ctor_names, &caps)) continue;
        if (!caps.hasAll()) continue;
        collectDeadAlternateCjsExportIdentifiers(allocator, ast, node.data.ternary.c, &dead_fallback_names) catch {};
        const kept = singleBlockStatement(ast, node.data.ternary.b) orelse node.data.ternary.b;
        const kept_ni = @intFromEnum(kept);
        if (kept_ni >= ast.nodes.items.len) continue;
        ast.nodes.items[i] = ast.nodes.items[kept_ni];
        changed = true;
    }
    if (changed and dead_fallback_names.count() > 0) {
        removeDeadFallbackSetupStatements(ast, &dead_fallback_names, &buffer_ctor_names);
    }
    return changed;
}

const BufferCapabilitySet = struct {
    from: bool = false,
    alloc: bool = false,
    alloc_unsafe: bool = false,
    alloc_unsafe_slow: bool = false,

    fn add(self: *BufferCapabilitySet, name: []const u8) bool {
        if (std.mem.eql(u8, name, "from")) {
            self.from = true;
            return true;
        }
        if (std.mem.eql(u8, name, "alloc")) {
            self.alloc = true;
            return true;
        }
        if (std.mem.eql(u8, name, "allocUnsafe")) {
            self.alloc_unsafe = true;
            return true;
        }
        if (std.mem.eql(u8, name, "allocUnsafeSlow")) {
            self.alloc_unsafe_slow = true;
            return true;
        }
        return false;
    }

    fn hasAll(self: BufferCapabilitySet) bool {
        return self.from and self.alloc and self.alloc_unsafe and self.alloc_unsafe_slow;
    }
};

fn collectNodeBufferCapabilityCondition(
    ast: *const Ast,
    idx: NodeIndex,
    ctor_names: *const std.StringHashMapUnmanaged(void),
    caps: *BufferCapabilitySet,
) bool {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@intFromEnum(idx)];
    switch (node.tag) {
        .parenthesized_expression => return collectNodeBufferCapabilityCondition(ast, node.data.unary.operand, ctor_names, caps),
        .logical_expression => {
            if (@as(Kind, @enumFromInt(node.data.binary.flags)) != .amp2) return false;
            return collectNodeBufferCapabilityCondition(ast, node.data.binary.left, ctor_names, caps) and
                collectNodeBufferCapabilityCondition(ast, node.data.binary.right, ctor_names, caps);
        },
        .static_member_expression => {
            const parts = staticMemberParts(ast, idx) orelse return false;
            const obj = ast.nodes.items[@intFromEnum(parts.object)];
            if (obj.tag != .identifier_reference) return false;
            if (!ctor_names.contains(ast.getText(obj.span))) return false;
            const prop = ast.nodes.items[@intFromEnum(parts.property)];
            if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
            return caps.add(ast.getText(prop.span));
        },
        else => return false,
    }
}

fn singleBlockStatement(ast: *const Ast, idx: NodeIndex) ?NodeIndex {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .block_statement) return null;
    const list = node.data.list;
    if (list.len != 1) return null;
    if (list.start >= ast.extra_data.items.len) return null;
    return @enumFromInt(ast.extra_data.items[list.start]);
}

fn collectDeadAlternateCjsExportIdentifiers(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    idx: NodeIndex,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start + list.len > ast.extra_data.items.len) return;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            try collectDeadAlternateCjsExportIdentifiers(allocator, ast, @enumFromInt(raw), out);
        }
        return;
    }
    if (node.tag != .expression_statement) return;
    const expr_idx = node.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return;
    if (!isCjsNamedExportLhs(ast, expr.data.binary.left)) return;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @intFromEnum(rhs_idx) >= ast.nodes.items.len) return;
    const rhs = ast.nodes.items[@intFromEnum(rhs_idx)];
    if (rhs.tag != .identifier_reference) return;
    try out.put(allocator, ast.getText(rhs.span), {});
}

fn removeDeadFallbackSetupStatements(
    ast: *Ast,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @enumFromInt(raw_stmt);
        if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@intFromEnum(stmt_idx)];
        if (!isDeadFallbackSetupStatement(ast, stmt, dead_names, buffer_ctor_names)) continue;
        ast.nodes.items[@intFromEnum(stmt_idx)] = .{
            .tag = .empty_statement,
            .span = stmt.span,
            .data = .{ .none = 0 },
        };
    }
}

fn isDeadFallbackSetupStatement(
    ast: *const Ast,
    stmt: Node,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag == .assignment_expression) {
        const root = staticMemberRootIdentifier(ast, expr.data.binary.left) orelse return false;
        return dead_names.contains(root);
    }
    if (expr.tag == .call_expression) {
        return isDeadFallbackCopyCall(ast, expr, dead_names, buffer_ctor_names);
    }
    return false;
}

fn isDeadFallbackCopyCall(
    ast: *const Ast,
    call: Node,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    const e = call.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 2 or args_start + args_len > ast.extra_data.items.len) return false;
    const first_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    const second_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start + 1]);
    if (first_idx.isNone() or second_idx.isNone()) return false;
    if (@intFromEnum(first_idx) >= ast.nodes.items.len or @intFromEnum(second_idx) >= ast.nodes.items.len) return false;
    const first = ast.nodes.items[@intFromEnum(first_idx)];
    const second = ast.nodes.items[@intFromEnum(second_idx)];
    if (first.tag != .identifier_reference or second.tag != .identifier_reference) return false;
    return buffer_ctor_names.contains(ast.getText(first.span)) and dead_names.contains(ast.getText(second.span));
}

fn staticMemberRootIdentifier(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    var current = idx;
    while (true) {
        const parts = staticMemberParts(ast, current) orelse return null;
        const obj = ast.nodes.items[@intFromEnum(parts.object)];
        if (obj.tag == .identifier_reference) return ast.getText(obj.span);
        current = parts.object;
    }
}

fn collectNodeBufferModuleObjectNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @enumFromInt(raw_stmt);
        try collectVarNamesMatchingInit(allocator, ast, stmt_idx, out, isRequireBufferCall);
    }
}

fn collectNodeBufferCtorNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    buffer_names: *const std.StringHashMapUnmanaged(void),
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @enumFromInt(raw_stmt);
        if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@intFromEnum(stmt_idx)];
        if (stmt.tag != .variable_declaration) continue;
        const e = stmt.data.extra;
        if (!ast.hasExtra(e, 2)) continue;
        const start = ast.readExtra(e, 1);
        const len = ast.readExtra(e, 2);
        if (start + len > ast.extra_data.items.len) continue;
        for (ast.extra_data.items[start .. start + len]) |raw_decl| {
            const decl_idx: NodeIndex = @enumFromInt(raw_decl);
            if (decl_idx.isNone() or @intFromEnum(decl_idx) >= ast.nodes.items.len) continue;
            const decl = ast.nodes.items[@intFromEnum(decl_idx)];
            if (decl.tag != .variable_declarator) continue;
            const de = decl.data.extra;
            if (!ast.hasExtra(de, 2)) continue;
            const name_idx: NodeIndex = @enumFromInt(ast.readExtra(de, 0));
            const init_idx: NodeIndex = @enumFromInt(ast.readExtra(de, 2));
            if (name_idx.isNone() or @intFromEnum(name_idx) >= ast.nodes.items.len) continue;
            if (!isNodeBufferCtorRead(ast, init_idx, buffer_names)) continue;
            const name = ast.nodes.items[@intFromEnum(name_idx)];
            if (name.tag == .identifier_reference or name.tag == .binding_identifier or name.tag == .assignment_target_identifier) {
                try out.put(allocator, ast.getText(name.span), {});
            }
        }
    }
}

fn collectVarNamesMatchingInit(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_idx: NodeIndex,
    out: *std.StringHashMapUnmanaged(void),
    comptime predicate: fn (*const Ast, NodeIndex) bool,
) std.mem.Allocator.Error!void {
    if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= ast.nodes.items.len) return;
    const stmt = ast.nodes.items[@intFromEnum(stmt_idx)];
    if (stmt.tag != .variable_declaration) return;
    const e = stmt.data.extra;
    if (!ast.hasExtra(e, 2)) return;
    const start = ast.readExtra(e, 1);
    const len = ast.readExtra(e, 2);
    if (start + len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[start .. start + len]) |raw_decl| {
        const decl_idx: NodeIndex = @enumFromInt(raw_decl);
        if (decl_idx.isNone() or @intFromEnum(decl_idx) >= ast.nodes.items.len) continue;
        const decl = ast.nodes.items[@intFromEnum(decl_idx)];
        if (decl.tag != .variable_declarator) continue;
        const de = decl.data.extra;
        if (!ast.hasExtra(de, 2)) continue;
        const name_idx: NodeIndex = @enumFromInt(ast.readExtra(de, 0));
        const init_idx: NodeIndex = @enumFromInt(ast.readExtra(de, 2));
        if (!predicate(ast, init_idx)) continue;
        if (name_idx.isNone() or @intFromEnum(name_idx) >= ast.nodes.items.len) continue;
        const name = ast.nodes.items[@intFromEnum(name_idx)];
        if (name.tag == .identifier_reference or name.tag == .binding_identifier or name.tag == .assignment_target_identifier) {
            try out.put(allocator, ast.getText(name.span), {});
        }
    }
}

fn programNode(ast: *const Ast) ?Node {
    if (ast.nodes.items.len == 0) return null;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return null;
    return root;
}

fn isRequireBufferCall(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .call_expression) return false;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const callee_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 0));
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.nodes.items[@intFromEnum(callee_idx)];
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(callee.span), "require")) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return false;
    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg.tag != .string_literal) return false;
    const spec = ast_mod.Ast.stripStringQuotes(ast.getText(arg.span));
    return std.mem.eql(u8, spec, "buffer") or std.mem.eql(u8, spec, "node:buffer");
}

fn isNodeBufferCtorRead(
    ast: *const Ast,
    idx: NodeIndex,
    buffer_names: *const std.StringHashMapUnmanaged(void),
) bool {
    const parts = staticMemberParts(ast, idx) orelse return false;
    const obj = ast.nodes.items[@intFromEnum(parts.object)];
    const prop = ast.nodes.items[@intFromEnum(parts.property)];
    if (obj.tag != .identifier_reference) return false;
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
    return buffer_names.contains(ast.getText(obj.span)) and std.mem.eql(u8, ast.getText(prop.span), "Buffer");
}

fn isModuleExportsAssignedNodeBufferObject(
    ast: *const Ast,
    stmt: Node,
    buffer_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return false;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return false;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @intFromEnum(rhs_idx) >= ast.nodes.items.len) return false;
    const rhs = ast.nodes.items[@intFromEnum(rhs_idx)];
    return rhs.tag == .identifier_reference and buffer_names.contains(ast.getText(rhs.span));
}

fn isModuleExportsLhs(ast: *const Ast, idx: NodeIndex) bool {
    const parts = staticMemberParts(ast, idx) orelse return false;
    const obj = ast.nodes.items[@intFromEnum(parts.object)];
    const prop = ast.nodes.items[@intFromEnum(parts.property)];
    return obj.tag == .identifier_reference and
        prop.tag == .identifier_reference and
        std.mem.eql(u8, ast.getText(obj.span), "module") and
        std.mem.eql(u8, ast.getText(prop.span), "exports");
}

fn isCjsNamedExportLhs(ast: *const Ast, idx: NodeIndex) bool {
    const outer = staticMemberParts(ast, idx) orelse return false;
    const prop = ast.nodes.items[@intFromEnum(outer.property)];
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
    const obj = ast.nodes.items[@intFromEnum(outer.object)];
    if (obj.tag == .identifier_reference and std.mem.eql(u8, ast.getText(obj.span), "exports")) {
        return true;
    }
    if (obj.tag != .static_member_expression) return false;
    const inner = staticMemberParts(ast, outer.object) orelse return false;
    const inner_obj = ast.nodes.items[@intFromEnum(inner.object)];
    const inner_prop = ast.nodes.items[@intFromEnum(inner.property)];
    return inner_obj.tag == .identifier_reference and
        inner_prop.tag == .identifier_reference and
        std.mem.eql(u8, ast.getText(inner_obj.span), "module") and
        std.mem.eql(u8, ast.getText(inner_prop.span), "exports");
}

fn moduleExportsRequireSpanAt(ast: *const Ast, idx: NodeIndex) ?@import("../lexer/token.zig").Span {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[@intFromEnum(idx)];
    if (stmt.tag == .block_statement) {
        const inner = singleBlockStatement(ast, idx) orelse return null;
        return moduleExportsRequireSpanAt(ast, inner);
    }
    if (stmt.tag == .if_statement) {
        const t = stmt.data.ternary;
        if (moduleExportsRequireSpanAt(ast, t.b)) |span| return span;
        if (!t.c.isNone()) return moduleExportsRequireSpanAt(ast, t.c);
        return null;
    }
    if (stmt.tag != .expression_statement) return null;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;
    const op: Kind = @enumFromInt(expr.data.binary.flags);
    if (op != .eq) return null;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return null;

    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @intFromEnum(rhs_idx) >= ast.nodes.items.len) return null;
    const rhs = ast.nodes.items[@intFromEnum(rhs_idx)];
    if (rhs.tag != .call_expression) return null;
    const e = rhs.data.extra;
    if (!ast.hasExtra(e, 2)) return null;

    const callee_idx = ast.readExtraNode(e, 0);
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[@intFromEnum(callee_idx)];
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(callee.span), "require")) return null;

    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return null;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg.tag != .string_literal) return null;
    return arg.span;
}

fn moduleExportsRequireTargetAt(m: *const Module, ast: *const Ast, idx: NodeIndex) ?ModuleIndex {
    const span = moduleExportsRequireSpanAt(ast, idx) orelse return null;
    for (m.import_records) |rec| {
        if (rec.kind != .require) continue;
        if (rec.resolved.isNone()) continue;
        if (rec.span.start == span.start and rec.span.end == span.end) return rec.resolved;
    }
    return null;
}

fn moduleExportsRequireProxyMatches(
    m: *const Module,
    infos: StmtInfos,
    stmt_idx: u32,
    target: ModuleIndex,
) bool {
    if (stmt_idx >= infos.stmts.len) return false;
    const ast = &(m.ast orelse return false);
    const stmt_ni = infos.stmts[stmt_idx].node_idx;
    if (stmt_ni >= ast.nodes.items.len) return false;
    const proxy_target = moduleExportsRequireTargetAt(m, ast, @enumFromInt(stmt_ni)) orelse return false;
    return @intFromEnum(proxy_target) == @intFromEnum(target);
}

fn staticMemberParts(ast: *const Ast, idx: NodeIndex) ?struct { object: NodeIndex, property: NodeIndex } {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag != .static_member_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 1)) return null;
    const obj_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 0));
    const prop_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 1));
    if (obj_idx.isNone() or prop_idx.isNone()) return null;
    if (@intFromEnum(obj_idx) >= ast.nodes.items.len or @intFromEnum(prop_idx) >= ast.nodes.items.len) return null;
    return .{ .object = obj_idx, .property = prop_idx };
}
