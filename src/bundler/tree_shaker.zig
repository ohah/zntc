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
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const ImportBinding = @import("binding_scanner.zig").ImportBinding;
const Linker = @import("linker.zig").Linker;
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const purity = @import("purity.zig");
const stmt_info_mod = @import("stmt_info.zig");
const StmtInfos = stmt_info_mod.ModuleStmtInfos;

/// `used_exports`의 all-exports-used sentinel. 모듈의 전체 export가 사용됨을 표시.
/// 일반 export 이름과 겹치지 않도록 의도적으로 JS 식별자 아닌 `"*"` 선택.
/// (export_bindings의 `exported_name == "*"`는 wildcard re-export로 의미가 다름 — 같은 문자열, 다른 공간)
pub const ALL_EXPORTS_SENTINEL: []const u8 = "*";

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
    /// seedOpaqueModule 재진입 방지용 visited bitset. crossModuleBFS에서 초기화.
    opaque_visited: ?std.DynamicBitSet = null,
    /// 모듈별 used export 존재 여부 (hasAnyUsedExportDirect 최적화: O(1) 조회).
    has_direct_used_export: []bool = &.{},
    /// prebuilt StmtInfo를 사용하는 모듈 마스크.
    /// prebuilt는 parse_arena가 소유하므로 deinit에서 해제하지 않는다.
    prebuilt_mask: ?std.DynamicBitSet = null,

    const max_fixpoint_iterations: u32 = 100;

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
        if (self.has_direct_used_export.len > 0) {
            self.allocator.free(self.has_direct_used_export);
        }
    }

    /// Tree-shaking 분석 (fixpoint 방식).
    ///
    /// 포함된 모듈의 import만 export 사용으로 카운트한다.
    /// included는 단조가 아님 — 축소(미사용 제거)와 확장(canonical/side-effect 전파)이 교차.
    /// 변경이 없을 때 수렴하며, 실제로는 2-3회 이내.
    pub fn analyze(self: *TreeShaker, entry_points: []const []const u8) !void {
        const mod_count = self.graph.moduleCount();

        // entry_set 먼저 계산 (자동 순수 판별에서 진입점 제외용)
        for (0..mod_count) |i| {
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
            for (entry_points) |ep| {
                if (std.mem.eql(u8, m.path, ep)) {
                    self.entry_set.set(i);
                    break;
                }
            }
        }

        // 자동 순수 판별: 진입점이 아닌 모듈의 top-level이 모두 순수하면 side_effects=false
        // (rolldown/esbuild 동작: package.json sideEffects 없어도 자동 감지)
        // 단, package.json sideEffects에 의해 결정된 값(user_defined)은 덮어쓰지 않는다
        // (rolldown DeterminedSideEffects::UserDefined 포팅).
        for (0..mod_count) |i| {
            const m = self.graph.moduleAtMut(ModuleIndex.fromUsize(i)) orelse continue;
            if (!m.side_effects) continue;
            if (m.side_effects_user_defined) continue;
            if (self.entry_set.isSet(i)) continue;
            if (m.ast) |ast| {
                const unresolved = if (m.semantic) |*s| &s.unresolved_references else null;
                if (isModulePure(&ast, unresolved)) {
                    m.side_effects = false;
                }
            }
        }

        for (0..mod_count) |i| {
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
            if (self.entry_set.isSet(i) or m.side_effects) {
                self.included.set(i);
            }
        }

        // dynamic import()의 target 모듈 집합. 정적 import_binding이 없어 심볼 도달성
        // 분석에서 누락되므로 별도 추적해 prune 단계에서 보호한다 (#1260).
        var dyn_import_targets = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer dyn_import_targets.deinit();
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

        // entry 모듈의 모든 export를 사용으로 마킹
        for (0..mod_count) |i| {
            if (self.entry_set.isSet(i)) try self.markAllExportsUsed(@intCast(i));
        }

        // StmtInfo 구축을 fixpoint 루프 전에 수행(#1558).
        // fixpoint 중에 BFS가 statement-level reachability를 사용하려면 미리 필요.
        // 모든 non-entry non-wrapped 모듈에 대해 구축 — included 여부는 이후 fixpoint에서 확장.
        var module_stmt_infos = try self.allocator.alloc(?StmtInfos, mod_count);
        for (module_stmt_infos) |*si| si.* = null;
        self.module_stmt_infos = module_stmt_infos;

        const reachable_stmts = try self.allocator.alloc(?std.DynamicBitSet, mod_count);
        for (reachable_stmts) |*rs| rs.* = null;
        self.reachable_stmts = reachable_stmts;

        var prebuilt_mask = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        self.prebuilt_mask = prebuilt_mask;
        for (0..mod_count) |i| {
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
            // wrapped(CJS/ESM wrap)는 body 전체가 한 function으로 래핑되어 statement 경계가
            // 무의미 — 모듈 단위 포함/제외만. entry 포함 non-wrapped 모두 stmt-level 도달성 분석.
            if (m.wrap_kind.isWrapped()) continue;

            if (m.prebuilt_stmt_info) |prebuilt| {
                module_stmt_infos[i] = prebuilt;
                prebuilt_mask.set(i);
                continue;
            }

            const sem = m.semantic orelse continue;
            const ast = &(m.ast orelse continue);
            module_stmt_infos[i] = stmt_info_mod.build(
                self.allocator,
                ast,
                sem.symbols.items,
                sem.symbol_ids,
                &sem.unresolved_references,
            ) catch null;
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
            var changed = false;
            const used_count_before = self.used_exports.count();
            const included_count_before = self.included.count();

            try self.buildSymToIbMaps();
            try self.crossModuleBFS(module_stmt_infos, reachable_stmts);

            for (0..mod_count) |i| {
                if (!self.included.isSet(i)) continue;
                const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
                // wrapped만 StmtInfo 없음 → live 필터 불가. 나머지(entry 포함)는 live_mod_idx 경로.
                const live_idx: ?u32 = if (m.wrap_kind.isWrapped()) null else @intCast(i);
                if (try self.processModuleImportsInner(m.*, live_idx)) changed = true;
            }

            if (try self.includeReExportSources(true)) changed = true;

            for (0..mod_count) |i| {
                if (!self.included.isSet(i)) continue;
                const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
                for (m.import_records) |rec| {
                    if (rec.resolved.isNone()) continue;
                    const target = @intFromEnum(rec.resolved);
                    const tmod = self.graph.getModule(rec.resolved) orelse continue;
                    if (self.included.isSet(target)) continue;
                    if (rec.kind == .require or tmod.side_effects or
                        tmod.wrap_kind.isWrapped())
                    {
                        self.included.set(target);
                        changed = true;
                    }
                }
            }

            if (self.used_exports.count() != used_count_before) changed = true;
            if (self.included.count() != included_count_before) changed = true;
            if (!changed) break;
        }

        // 미사용 sideEffects=false 모듈 제거.
        for (0..mod_count) |i| {
            if (!self.included.isSet(i)) continue;
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
            if (self.entry_set.isSet(i) or m.side_effects or m.wrap_kind.isWrapped()) continue;
            if (dyn_import_targets.isSet(i)) continue; // #1260: dynamic import target 보호
            if (!self.hasAnyUsedExport(@intCast(i)) and !self.hasAnyUsedExportDirect(@intCast(i))) {
                self.included.unset(i);
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

    /// import binding의 심볼이 해당 모듈에서 reachable statement에서 참조되는지 확인.
    /// emitter가 export_bindings 필터링에 사용.
    pub fn isImportLiveInModule(self: *const TreeShaker, module_index: u32, local_name: []const u8) bool {
        if (module_index >= self.reachable_stmts.len) return true;
        const reachable = self.reachable_stmts[module_index] orelse return true;
        const infos = if (module_index < self.module_stmt_infos.len)
            (self.module_stmt_infos[module_index] orelse return true)
        else
            return true;
        const m = self.graph.getModule(ModuleIndex.fromUsize(module_index)) orelse return true;
        const sem = m.semantic orelse return true;
        if (sem.scope_maps.len == 0) return true;
        const sym_idx = sem.scope_maps[0].get(local_name) orelse return true;

        // 역인덱스로 이 심볼을 참조하는 statement 중 reachable한 것이 있는지 확인
        if (sym_idx < infos.sym_to_referencing_stmts.len) {
            for (infos.sym_to_referencing_stmts[sym_idx]) |si| {
                if (reachable.isSet(si)) return true;
            }
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
            .expression_statement => purity.isExprPure(ast, stmt.data.unary.operand, unresolved_globals),

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
        const mod = self.graph.getModule(ModuleIndex.fromUsize(mod_idx)) orelse return;
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
        var queue: std.ArrayListUnmanaged(BfsItem) = .empty;
        defer queue.deinit(self.allocator);

        const mod_count = self.graph.moduleCount();
        var ov = try std.DynamicBitSet.initEmpty(self.allocator, mod_count);
        defer ov.deinit();
        self.opaque_visited = ov;

        // 시드 1: entry module의 export 선언 statement + side-effect statement
        for (0..mod_count) |i| {
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
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

            // entry는 번들 진입점 — 모든 top-level statement가 실행되어야 하므로 전체 시드.
            // side_effects=true 모듈은 side-effect stmt만 시드.
            // side_effects=false 모듈은 enqueue의 lazy 시드로 처리 (사용 시에만).
            if (self.entry_set.isSet(i)) {
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
                    if (infos.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
                        try self.enqueue(@intCast(i), stmt_idx, reachable_stmts, &queue);
                    }
                }
                // dynamic import target도 re-export 체인 따라 transitive 모듈까지
                // 전파해야 함(#1260). seedOpaqueModule은 opaque_visited로 중복 방지.
                try self.seedOpaqueModule(@intCast(i), &queue, module_stmt_infos, reachable_stmts);
            }
        }

        // BFS 루프
        var head: u32 = 0;
        while (head < queue.items.len) : (head += 1) {
            const item = queue.items[head];
            const infos = module_stmt_infos[item.mod] orelse continue;
            if (item.stmt >= infos.stmts.len) continue;

            for (infos.stmts[item.stmt].referenced_symbols) |ref_sym| {
                // (1) 로컬 심볼: 같은 모듈의 종속 statement
                if (infos.declaredStmtBySymbol(ref_sym)) |dep_stmt| {
                    try self.enqueue(item.mod, dep_stmt, reachable_stmts, &queue);
                }

                // (2) import binding: 타겟 모듈로 점프
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
        }

        // BFS 후: reachable statement 기반 used_exports 추가 마킹
        // BFS 중 markExportUsed로 마킹된 것은 유지 (clearUsedExports 하지 않음)
        for (0..mod_count) |i| {
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
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
            if (self.module_stmt_infos[mod]) |infos| {
                if (stmt < infos.stmts.len) {
                    for (infos.stmts[stmt].declared_symbols) |declared_sym| {
                        if (declared_sym < infos.sym_to_side_effect_stmts.len) {
                            for (infos.sym_to_side_effect_stmts[declared_sym]) |si| {
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
    }

    /// import binding을 따라 타겟 모듈의 export statement를 시드.
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
        const m = self.graph.getModule(ModuleIndex.fromUsize(mod_idx)) orelse return;
        if (ib_idx >= m.import_bindings.len) return;
        const ib = m.import_bindings[ib_idx];
        if (ib.import_record_index >= m.import_records.len) return;
        const rec = m.import_records[ib.import_record_index];
        if (rec.resolved.isNone()) return;
        const target = @intFromEnum(rec.resolved);
        if (self.graph.getModule(rec.resolved) == null) return;

        if (ib.kind == .namespace) {
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

        // #1603 Phase 1b: `.named` 바인딩이 target의 `export * as X`를 겨냥하고
        // namespace_used_properties가 populate 되어 있으면, 해당 subset을 re-export 소스 모듈에 seed.
        // 이렇게 하지 않으면 seedExport가 idx.ts의 "M"를 resolve해도 idx.ts scope에
        // "M" 로컬이 없어 enqueue가 실패 → source 모듈 statement 도달성 누락.
        if (ib.kind == .named and ib.namespace_used_properties != null) {
            const target_module = self.graph.getModule(rec.resolved).?;
            for (target_module.export_bindings) |eb| {
                if (eb.kind != .re_export_namespace) continue;
                if (!std.mem.eql(u8, eb.exported_name, ib.imported_name)) continue;
                const rec_idx = eb.import_record_index orelse break;
                if (rec_idx >= target_module.import_records.len) break;
                const inner_src = @intFromEnum(target_module.import_records[rec_idx].resolved);
                if (self.graph.getModule(target_module.import_records[rec_idx].resolved) == null) break;

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
        const mod_count = self.graph.moduleCount();
        const canonical = self.linker.resolveExportChain(@enumFromInt(@as(u32, @intCast(target_mod))), imported_name, 0) orelse {
            // 해석 실패: 전체 포함
            if (target_mod < mod_count) self.included.set(target_mod);
            return;
        };
        const canon_mod = canonical.module_index.toU32();
        const canon_m = self.graph.getModule(canonical.module_index) orelse return;

        try self.markExportUsed(canon_mod, canonical.export_name);
        self.included.set(canon_mod);

        // namespace barrel re-export: canonical이 namespace import를 가리키면
        // 소스 모듈의 모든 export를 시드해야 함 (import * as z; export { z } 패턴)
        const canon_local = self.linker.getExportLocalName(@intCast(canon_mod), canonical.export_name) orelse canonical.export_name;
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

        if (canon_mod != target_mod and target_mod < mod_count) {
            try self.markExportUsed(@intCast(target_mod), imported_name);
            self.included.set(target_mod);
            // 중간 모듈의 export 선언 statement도 reachable로 마킹
            const mid_module = self.graph.getModule(ModuleIndex.fromUsize(target_mod)).?.*;
            if (mid_module.semantic) |mid_sem| {
                if (mid_sem.scope_maps.len > 0) {
                    const mid_local = self.linker.getExportLocalName(@intCast(target_mod), imported_name) orelse imported_name;
                    if (mid_sem.scope_maps[0].get(mid_local)) |mid_sym| {
                        if (module_stmt_infos[target_mod]) |mid_infos| {
                            if (mid_infos.declaredStmtBySymbol(@intCast(mid_sym))) |mid_stmt| {
                                if (reachable_stmts[target_mod] == null) {
                                    reachable_stmts[target_mod] = try std.DynamicBitSet.initEmpty(self.allocator, mid_infos.stmts.len);
                                }
                                try self.enqueue(@intCast(target_mod), mid_stmt, reachable_stmts, queue);
                            }
                        }
                    }
                }
            }
        }

        const target_module = canon_m;
        const target_sem = target_module.semantic orelse {
            try self.seedOpaqueModule(@intCast(canon_mod), queue, module_stmt_infos, reachable_stmts);
            return;
        };
        if (target_sem.scope_maps.len == 0) return;

        const local_name = self.linker.getExportLocalName(@intCast(canon_mod), canonical.export_name) orelse canonical.export_name;
        const sym_idx = target_sem.scope_maps[0].get(local_name) orelse return;
        const target_infos = module_stmt_infos[canon_mod] orelse {
            try self.seedOpaqueModule(@intCast(canon_mod), queue, module_stmt_infos, reachable_stmts);
            return;
        };
        const target_stmt = target_infos.declaredStmtBySymbol(@intCast(sym_idx)) orelse return;

        if (reachable_stmts[canon_mod] == null) {
            reachable_stmts[canon_mod] = try std.DynamicBitSet.initEmpty(self.allocator, target_infos.stmts.len);
        }
        try self.enqueue(@intCast(canon_mod), target_stmt, reachable_stmts, queue);

        // side-effect statement는 enqueueStmt에서 lazy 시드됨
    }

    /// StmtInfo 없는 모듈 (entry, CJS 등)의 import를 BFS로 전파.
    fn seedOpaqueModule(
        self: *TreeShaker,
        mod_idx: u32,
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        const m = self.graph.getModule(ModuleIndex.fromUsize(mod_idx)) orelse return;
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
                    if (eb.kind.isReExportAll()) {
                        try self.markAllExportsUsed(@intCast(src));
                        self.included.set(src);
                        try self.seedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
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
        const m = self.graph.getModule(ModuleIndex.fromUsize(mod_idx)) orelse return;
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export and !eb.kind.isReExportAll()) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= m.import_records.len) continue;
            const src_idx = m.import_records[rec_idx].resolved;
            if (self.graph.getModule(src_idx) == null) continue;
            const src = @intFromEnum(src_idx);
            if (eb.kind.isReExportAll()) {
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
    }

    fn includeReExportSources(self: *TreeShaker, check_used: bool) !bool {
        var changed = false;
        for (0..self.graph.moduleCount()) |i| {
            if (!self.included.isSet(i)) continue;
            const m = self.graph.getModule(ModuleIndex.fromUsize(i)) orelse continue;
            for (m.export_bindings) |eb| {
                if (eb.kind != .re_export and !eb.kind.isReExportAll()) continue;
                if (check_used and !self.isExportUsed(@intCast(i), eb.exported_name)) continue;
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const src_idx = m.import_records[rec_idx].resolved;
                        if (self.graph.getModule(src_idx) != null) {
                            const src = @intFromEnum(src_idx);
                            if (!self.included.isSet(src)) {
                                self.included.set(src);
                                changed = true;
                            }
                            if (eb.kind == .re_export_namespace) {
                                // #1603 Phase 1b: 모든 소비자의 `namespace_used_properties`를
                                // 집계해 subset이 결정 가능하면 해당 member만 used로 마킹.
                                // 하나라도 opaque(null)이면 전체 사용 fallback.
                                if (try self.tryMarkReExportNsSubset(@intCast(i), eb.exported_name, @intCast(src))) continue;
                                try self.markAllExportsUsed(@intCast(src));
                            } else if (!check_used) {
                                try self.markAllExportsUsed(@intCast(src));
                            }
                        }
                    }
                }
            }
        }
        return changed;
    }

    /// #1603 Phase 1b: `export * as X from './src'` 재export에 대해 모든 소비자의 member 접근
    /// 집합을 집계. 반환값 `true`: precision 성공(또는 소비자 0명 — markAll 불필요).
    /// `false`: 적어도 한 소비자가 opaque → 호출자가 전체 fallback 적용.
    fn tryMarkReExportNsSubset(
        self: *TreeShaker,
        reexport_mod: u32,
        reexport_name: []const u8,
        src_mod: u32,
    ) !bool {
        var union_set: std.StringHashMapUnmanaged(void) = .{};
        defer union_set.deinit(self.allocator);

        // 소비자 검색: 모든 모듈의 .named import_bindings에서 이 re-export 소비자 찾기
        var cit = self.graph.modulesIterator();
        while (cit.next()) |consumer_ptr| {
            const consumer = consumer_ptr.*;
            for (consumer.import_bindings) |ib| {
                if (!Linker.isReExportNsConsumer(consumer, ib, reexport_mod, reexport_name)) continue;

                const props = ib.namespace_used_properties orelse return false; // opaque → fallback
                for (props) |p| try union_set.put(self.allocator, p, {});
            }
        }

        // union에 포함된 member만 source 모듈에서 used로 마킹.
        // 소비자 0명이면 union_set이 비어 아무것도 마킹 안 함 — precision 성공으로 취급(markAll 불필요).
        var kit = union_set.keyIterator();
        while (kit.next()) |key| {
            try self.markExportUsed(src_mod, key.*);
        }
        return true;
    }

    /// import binding → export 마킹 + canonical 모듈 포함.
    /// live_mod_idx가 non-null이면 StmtInfo 도달성 기반 추가 필터링 적용.
    fn processModuleImportsInner(self: *TreeShaker, m: Module, live_mod_idx: ?u32) !bool {
        var newly_included = false;
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target_mod = @intFromEnum(rec.resolved);
            if (self.graph.getModule(rec.resolved) == null) continue;

            if (live_mod_idx) |idx| {
                if (!self.isImportLiveInModule(idx, ib.local_name)) continue;
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

    fn markAllExportsUsed(self: *TreeShaker, module_index: u32) !void {
        const m = self.graph.getModule(ModuleIndex.fromUsize(module_index)) orelse return;
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
        const m = self.graph.getModule(ModuleIndex.fromUsize(module_index)) orelse return false;
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
