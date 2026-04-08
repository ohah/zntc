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
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const ImportBinding = @import("binding_scanner.zig").ImportBinding;
const Linker = @import("linker.zig").Linker;
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const purity = @import("purity.zig");
const stmt_info_mod = @import("stmt_info.zig");
const StmtInfos = stmt_info_mod.ModuleStmtInfos;

pub const TreeShaker = struct {
    allocator: std.mem.Allocator,
    modules: []const Module,
    linker: *const Linker,
    included: std.DynamicBitSet,
    used_exports: std.StringHashMap(void),
    entry_set: std.DynamicBitSet,
    /// 모듈별 local re-export name set. isImportBindingUsed의 O(E) 스캔을 O(1)로 최적화.
    /// analyze()에서 사전 구축, null이면 해당 모듈에 local re-export 없음.
    re_export_sets: []?std.StringHashMap(void) = &.{},
    /// 모듈별 StmtInfo (심볼 기반 도달성 분석). analyze()에서 구축.
    module_stmt_infos: []?StmtInfos = &.{},
    /// 모듈별 도달성 bitset 캐시. fixpoint 수렴 후 계산.
    reachable_stmts: []?std.DynamicBitSet = &.{},
    /// 모듈별 sym_idx → import_binding_index 맵. 크로스-모듈 BFS에서 사용.
    sym_to_ib: []?[]?u32 = &.{},
    /// seedOpaqueModule 재진입 방지용 visited bitset. crossModuleBFS에서 초기화.
    opaque_visited: ?std.DynamicBitSet = null,
    /// 모듈별 used export 존재 여부 (hasAnyUsedExportDirect 최적화: O(1) 조회).
    has_direct_used_export: []bool = &.{},

    const max_fixpoint_iterations: u32 = 100;

    pub fn init(allocator: std.mem.Allocator, modules: []const Module, linker: *const Linker) !TreeShaker {
        var included = try std.DynamicBitSet.initEmpty(allocator, modules.len);
        errdefer included.deinit();
        var entry_set = try std.DynamicBitSet.initEmpty(allocator, modules.len);
        errdefer entry_set.deinit();

        return .{
            .allocator = allocator,
            .modules = modules,
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
            for (self.module_stmt_infos) |*si| {
                if (si.*) |*infos| infos.deinit();
            }
            self.allocator.free(self.module_stmt_infos);
        }
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
        // entry_set 먼저 계산 (자동 순수 판별에서 진입점 제외용)
        for (self.modules, 0..) |m, i| {
            for (entry_points) |ep| {
                if (std.mem.eql(u8, m.path, ep)) {
                    self.entry_set.set(i);
                    break;
                }
            }
        }

        // 자동 순수 판별: 진입점이 아닌 모듈의 top-level이 모두 순수하면 side_effects=false
        // (rolldown/esbuild 동작: package.json sideEffects 없어도 자동 감지)
        for (self.modules, 0..) |m, i| {
            if (!m.side_effects) continue;
            if (self.entry_set.isSet(i)) continue;
            if (m.ast) |ast| {
                if (isModulePure(&ast)) {
                    const mutable_modules: [*]Module = @constCast(self.modules.ptr);
                    mutable_modules[i].side_effects = false;
                }
            }
        }

        for (self.modules, 0..) |m, i| {
            if (self.entry_set.isSet(i) or m.side_effects) {
                self.included.set(i);
            }
        }

        // 모듈별 re-export local name set 사전 구축 (isImportBindingUsed 최적화)
        var re_export_sets = try self.allocator.alloc(?std.StringHashMap(void), self.modules.len);
        defer {
            for (re_export_sets) |*s| {
                if (s.*) |*set| set.deinit();
            }
            self.allocator.free(re_export_sets);
        }
        for (self.modules, 0..) |m, i| {
            var has_local_reexport = false;
            for (m.export_bindings) |eb| {
                if (eb.kind == .local) {
                    has_local_reexport = true;
                    break;
                }
            }
            if (has_local_reexport) {
                var set = std.StringHashMap(void).init(self.allocator);
                for (m.export_bindings) |eb| {
                    if (eb.kind == .local) try set.put(eb.local_name, {});
                }
                re_export_sets[i] = set;
            } else {
                re_export_sets[i] = null;
            }
        }
        self.re_export_sets = re_export_sets;

        // has_direct_used_export 배열 초기화 (hasAnyUsedExportDirect O(1) 조회용)
        const has_due = try self.allocator.alloc(bool, self.modules.len);
        @memset(has_due, false);
        self.has_direct_used_export = has_due;

        // --- Incremental fixpoint ---
        // used_exports는 단조 증가 (한번 marked → 유지). clearUsedExports 불필요.
        // included_snapshot: 직전 상태. 새로 included된 모듈만 추적.

        // 1단계: entry 모듈의 모든 export를 사용으로 마킹
        for (self.modules, 0..) |_, i| {
            if (self.entry_set.isSet(i)) try self.markAllExportsUsed(@intCast(i));
        }

        // 2단계: included 변화가 없을 때까지 반복
        var iteration: u32 = 0;
        while (iteration < max_fixpoint_iterations) : (iteration += 1) {
            var changed = false;

            // (a) 포함된 모듈의 import → export 마킹 + canonical 모듈 포함
            for (self.modules, 0..) |m, i| {
                if (!self.included.isSet(i)) continue;
                if (try self.processModuleImports(m)) changed = true;
            }

            // (b) re-export 소스 포함
            if (try self.includeReExportSources(true)) changed = true;

            // (c) 포함된 모듈이 import하는 side_effects/require/wrapped 모듈 전파
            for (self.modules, 0..) |m, i| {
                if (!self.included.isSet(i)) continue;
                for (m.import_records) |rec| {
                    if (rec.resolved.isNone()) continue;
                    const target = @intFromEnum(rec.resolved);
                    if (target >= self.modules.len) continue;
                    if (self.included.isSet(target)) continue;
                    if (rec.kind == .require or self.modules[target].side_effects or
                        self.modules[target].wrap_kind.isWrapped())
                    {
                        self.included.set(target);
                        changed = true;
                    }
                }
            }

            if (!changed) break;
        }

        // fixpoint 후 미사용 sideEffects=false 모듈 제거 (1회만 수행, oscillation 방지)
        for (self.modules, 0..) |m, i| {
            if (!self.included.isSet(i)) continue;
            if (self.entry_set.isSet(i) or m.side_effects or m.wrap_kind.isWrapped()) continue;
            if (!self.hasAnyUsedExport(@intCast(i))) {
                self.included.unset(i);
            }
        }

        // 2차: 심볼 기반 도달성 분석 (rolldown 방식)
        // StmtInfo 구축 → reachable_stmts 계산 → used_exports 재계산을 수렴할 때까지 반복.
        // 순환 의존에서 dead import가 순환 경로로 used로 마킹되는 문제를 해결.
        var module_stmt_infos = try self.allocator.alloc(?StmtInfos, self.modules.len);
        for (module_stmt_infos) |*si| si.* = null;
        self.module_stmt_infos = module_stmt_infos;

        const reachable_stmts = try self.allocator.alloc(?std.DynamicBitSet, self.modules.len);
        for (reachable_stmts) |*rs| rs.* = null;
        self.reachable_stmts = reachable_stmts;

        // StmtInfo 구축 (entry, CJS 제외)
        for (self.modules, 0..) |m, i| {
            if (!self.included.isSet(i)) continue;
            if (self.entry_set.isSet(i) or m.wrap_kind.isWrapped()) continue;
            const sem = m.semantic orelse continue;
            const ast = &(m.ast orelse continue);
            module_stmt_infos[i] = stmt_info_mod.build(
                self.allocator,
                ast,
                sem.symbols,
                sem.symbol_ids,
            ) catch null;
        }

        // 크로스-모듈 BFS: rolldown 방식 — import binding을 따라 모듈 횡단
        try self.buildSymToIbMaps();
        try self.crossModuleBFS(module_stmt_infos, reachable_stmts);

        // 미사용 sideEffects=false 모듈 제거
        for (self.modules, 0..) |m, i| {
            if (!self.included.isSet(i)) continue;
            if (self.entry_set.isSet(i) or m.side_effects or m.wrap_kind.isWrapped()) continue;
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
        if (module_index >= self.modules.len) return false;
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
        const m = self.modules[module_index];
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
    fn isModulePure(ast: *const Ast) bool {
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
            if (!isStatementPure(ast, stmt)) return false;
        }
        return true;
    }

    fn isStatementPure(ast: *const Ast, stmt: Node) bool {
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
                return isStatementPure(ast, decl);
            },

            .export_default_declaration => {
                const inner_idx = stmt.data.unary.operand;
                if (inner_idx.isNone() or @intFromEnum(inner_idx) >= ast.nodes.items.len) return false;
                const inner = ast.nodes.items[@intFromEnum(inner_idx)];
                return switch (inner.tag) {
                    .function_declaration => true,
                    .class_declaration => !purity.classHasSideEffects(ast, inner),
                    else => purity.isExprPure(ast, inner_idx),
                };
            },

            .function_declaration => true,
            .class_declaration => !purity.classHasSideEffects(ast, stmt),

            .ts_interface_declaration,
            .ts_type_alias_declaration,
            => true,

            .ts_enum_declaration,
            .ts_module_declaration,
            => false,

            .variable_declaration => purity.isVarDeclPure(ast, stmt),
            .expression_statement => purity.isExprPure(ast, stmt.data.unary.operand),

            .empty_statement => true,

            else => false,
        };
    }

    // ============================================================
    // Internal
    // ============================================================

    /// 하나의 포함된 모듈에 대해 import binding → export 마킹 + canonical 모듈 포함.
    /// 새 모듈이 포함되면 true를 반환하여 fixpoint 루프가 계속되도록 한다.
    /// 포함된 모듈의 re-export 소스를 포함시키고 export를 마킹한다.
    /// check_used=true이면 해당 export가 used인 경우만 처리 (fixpoint/수렴 루프).
    /// check_used=false이면 모든 re-export 소스를 무조건 포함 (초기 entry 시딩).
    /// sym_idx → import_binding_index 맵 구축 (크로스-모듈 BFS용).
    fn buildSymToIbMaps(self: *TreeShaker) !void {
        var maps = try self.allocator.alloc(?[]?u32, self.modules.len);
        for (maps) |*m| m.* = null;
        for (self.modules, 0..) |mod, i| {
            if (!self.included.isSet(i)) continue;
            const sem = mod.semantic orelse continue;
            if (sem.scope_maps.len == 0 or mod.import_bindings.len == 0) continue;
            var arr = try self.allocator.alloc(?u32, sem.symbols.len);
            for (arr) |*a| a.* = null;
            for (mod.import_bindings, 0..) |ib, ib_idx| {
                if (sem.scope_maps[0].get(ib.local_name)) |sym_idx| {
                    if (sym_idx < arr.len) arr[sym_idx] = @intCast(ib_idx);
                }
            }
            maps[i] = arr;
        }
        self.sym_to_ib = maps;
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

        var ov = try std.DynamicBitSet.initEmpty(self.allocator, self.modules.len);
        defer ov.deinit();
        self.opaque_visited = ov;

        // 시드 1: entry module의 export 선언 statement + side-effect statement
        for (self.modules, 0..) |m, i| {
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

            // side_effects=true 모듈: side-effect statement 즉시 시드 (fixpoint에서 포함됨)
            // side_effects=false 모듈: enqueue의 lazy 시드로 처리 (모듈 사용 시에만)
            if (m.side_effects) {
                for (infos.stmts, 0..) |stmt, si| {
                    if (stmt.has_side_effects) {
                        try self.enqueue(@intCast(i), @intCast(si), reachable_stmts, &queue);
                    }
                }
            }

            // used export 선언 statement 시드 (rolldown include_symbol 동등).
            // entry: 모든 export. sideEffects:false: fixpoint에서 used인 export만.
            // sideEffects:true non-entry: BFS가 side-effect statement에서 시작하므로 불필요.
            if (self.entry_set.isSet(i) or !m.side_effects) {
                const sem = m.semantic orelse continue;
                if (sem.scope_maps.len == 0) continue;
                const mi: u32 = @intCast(i);
                for (m.export_bindings) |eb| {
                    if (eb.kind == .re_export_all) continue;
                    if (!self.entry_set.isSet(i) and !self.isExportUsed(mi, eb.exported_name)) continue;
                    if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                        if (infos.declaredStmtBySymbol(@intCast(sym_idx))) |stmt_idx| {
                            try self.enqueue(@intCast(i), stmt_idx, reachable_stmts, &queue);
                        }
                    }
                }
                if (self.entry_set.isSet(i)) {
                    try self.seedOpaqueModule(@intCast(i), &queue, module_stmt_infos, reachable_stmts);
                }
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
                                try self.followImport(item.mod, ib_idx, &queue, module_stmt_infos, reachable_stmts);
                            }
                        }
                    }
                }
            }
        }

        // BFS 후: reachable statement 기반 used_exports 추가 마킹
        // BFS 중 markExportUsed로 마킹된 것은 유지 (clearUsedExports 하지 않음)
        for (self.modules, 0..) |m, i| {
            const infos = module_stmt_infos[i] orelse continue;
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                    if (infos.declaredStmtBySymbol(@intCast(sym_idx))) |stmt_idx| {
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
        queue: *std.ArrayListUnmanaged(BfsItem),
        module_stmt_infos: []?StmtInfos,
        reachable_stmts: []?std.DynamicBitSet,
    ) std.mem.Allocator.Error!void {
        if (mod_idx >= self.modules.len) return;
        const m = self.modules[mod_idx];
        if (ib_idx >= m.import_bindings.len) return;
        const ib = m.import_bindings[ib_idx];
        if (ib.import_record_index >= m.import_records.len) return;
        const rec = m.import_records[ib.import_record_index];
        if (rec.resolved.isNone()) return;
        const target = @intFromEnum(rec.resolved);
        if (target >= self.modules.len) return;

        if (ib.kind == .namespace) {
            if (ib.namespace_used_properties) |props| {
                for (props) |prop_name| {
                    try self.seedExport(target, prop_name, queue, module_stmt_infos, reachable_stmts);
                }
            } else {
                try self.markAllExportsUsed(@intCast(target));
                self.included.set(target);
                try self.seedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
            }
            return;
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
        const canonical = self.linker.resolveExportChain(@enumFromInt(@as(u32, @intCast(target_mod))), imported_name, 0) orelse {
            // 해석 실패: 전체 포함
            if (target_mod < self.modules.len) self.included.set(target_mod);
            return;
        };
        const canon_mod = @intFromEnum(canonical.module_index);
        if (canon_mod >= self.modules.len) return;

        try self.markExportUsed(@intCast(canon_mod), canonical.export_name);
        self.included.set(canon_mod);

        // namespace barrel re-export: canonical이 namespace import를 가리키면
        // 소스 모듈의 모든 export를 시드해야 함 (import * as z; export { z } 패턴)
        const canon_local = self.linker.getExportLocalName(@intCast(canon_mod), canonical.export_name) orelse canonical.export_name;
        for (self.modules[canon_mod].import_bindings) |cib| {
            if (cib.kind == .namespace and std.mem.eql(u8, cib.local_name, canon_local)) {
                if (cib.import_record_index < self.modules[canon_mod].import_records.len) {
                    const ns_src = @intFromEnum(self.modules[canon_mod].import_records[cib.import_record_index].resolved);
                    if (ns_src < self.modules.len) {
                        try self.markAllExportsUsed(@intCast(ns_src));
                        self.included.set(ns_src);
                        try self.seedAllStmts(@intCast(ns_src), queue, module_stmt_infos, reachable_stmts);
                    }
                }
                break;
            }
        }

        if (canon_mod != target_mod and target_mod < self.modules.len) {
            try self.markExportUsed(@intCast(target_mod), imported_name);
            self.included.set(target_mod);
            // 중간 모듈의 export 선언 statement도 reachable로 마킹
            const mid_module = self.modules[target_mod];
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

        const target_module = self.modules[canon_mod];
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
        if (mod_idx >= self.modules.len) return;
        if (self.opaque_visited) |ov| {
            if (ov.isSet(mod_idx)) return;
        }
        if (self.opaque_visited) |*ov| ov.set(mod_idx);

        const m = self.modules[mod_idx];
        for (m.import_bindings) |ib| {
            if (!self.isImportBindingUsed(m, ib)) continue;
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target = @intFromEnum(rec.resolved);
            if (target >= self.modules.len) continue;

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
            if (eb.kind != .re_export and eb.kind != .re_export_all) continue;
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const src = @intFromEnum(m.import_records[rec_idx].resolved);
                    if (src >= self.modules.len) continue;
                    if (eb.kind == .re_export_all) {
                        try self.markAllExportsUsed(@intCast(src));
                        self.included.set(src);
                        try self.seedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
                    } else {
                        try self.seedExport(src, eb.local_name, queue, module_stmt_infos, reachable_stmts);
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
        if (mod_idx >= self.modules.len) return;
        const m = self.modules[mod_idx];
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export and eb.kind != .re_export_all) continue;
            const rec_idx = eb.import_record_index orelse continue;
            if (rec_idx >= m.import_records.len) continue;
            const src = @intFromEnum(m.import_records[rec_idx].resolved);
            if (src >= self.modules.len) continue;
            if (eb.kind == .re_export_all) {
                self.included.set(src);
                try self.seedAllStmts(@intCast(src), queue, module_stmt_infos, reachable_stmts);
            } else {
                try self.seedExport(src, eb.local_name, queue, module_stmt_infos, reachable_stmts);
            }
        }
        // namespace import 전파: import * as X에서 X가 사용되면 소스 모듈도 시드
        for (m.import_bindings) |ib| {
            if (ib.kind != .namespace) continue;
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target = @intFromEnum(rec.resolved);
            if (target >= self.modules.len) continue;
            self.included.set(target);
            try self.seedAllStmts(@intCast(target), queue, module_stmt_infos, reachable_stmts);
        }
    }

    fn includeReExportSources(self: *TreeShaker, check_used: bool) !bool {
        var changed = false;
        for (self.modules, 0..) |m, i| {
            if (!self.included.isSet(i)) continue;
            for (m.export_bindings) |eb| {
                if (eb.kind != .re_export and eb.kind != .re_export_all) continue;
                if (check_used and !self.isExportUsed(@intCast(i), eb.exported_name)) continue;
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const src = @intFromEnum(m.import_records[rec_idx].resolved);
                        if (src < self.modules.len) {
                            if (!self.included.isSet(src)) {
                                self.included.set(src);
                                changed = true;
                            }
                            if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) {
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

    /// import binding → export 마킹 + canonical 모듈 포함.
    /// live_mod_idx가 non-null이면 StmtInfo 도달성 기반 추가 필터링 적용.
    fn processModuleImportsInner(self: *TreeShaker, m: Module, live_mod_idx: ?u32) !bool {
        var newly_included = false;
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const target_mod = @intFromEnum(rec.resolved);
            if (target_mod >= self.modules.len) continue;

            if (!self.isImportBindingUsed(m, ib)) continue;
            if (live_mod_idx) |idx| {
                if (!self.isImportLiveInModule(idx, ib.local_name)) continue;
            }

            const canonical = self.linker.resolveExportChain(rec.resolved, ib.imported_name, 0);
            if (canonical) |c| {
                const canon_idx = @intFromEnum(c.module_index);
                if (canon_idx < self.modules.len) {
                    try self.markExportUsed(@intCast(canon_idx), c.export_name);
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
                if (ib.namespace_used_properties) |props| {
                    for (props) |prop_name| {
                        if (self.linker.resolveExportChain(rec.resolved, prop_name, 0)) |c| {
                            const canon_idx = @intFromEnum(c.module_index);
                            if (canon_idx < self.modules.len) {
                                try self.markExportUsed(@intCast(canon_idx), c.export_name);
                                if (!self.included.isSet(canon_idx)) {
                                    self.included.set(canon_idx);
                                    newly_included = true;
                                }
                            }
                        }
                        try self.markExportUsed(@intCast(target_mod), prop_name);
                    }
                } else {
                    try self.markAllExportsUsed(@intCast(target_mod));
                }
                if (!self.included.isSet(target_mod)) {
                    self.included.set(target_mod);
                    newly_included = true;
                }
            }
        }
        return newly_included;
    }

    fn processModuleImports(self: *TreeShaker, m: Module) !bool {
        return self.processModuleImportsInner(m, null);
    }

    fn isImportBindingUsed(self: *const TreeShaker, m: Module, ib: ImportBinding) bool {
        if (m.semantic) |sem| {
            if (sem.scope_maps.len > 0) {
                if (sem.scope_maps[0].get(ib.local_name)) |sym_idx| {
                    if (sym_idx < sem.symbols.len and sem.symbols[sym_idx].reference_count > 0) return true;
                }
            }
        } else return true;

        const mod_idx = @intFromEnum(m.index);
        if (mod_idx < self.re_export_sets.len) {
            if (self.re_export_sets[mod_idx]) |set| {
                return set.contains(ib.local_name);
            }
        }
        return false;
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
        if (module_index >= self.modules.len) return;
        // 순환 export * 방지: 이미 처리한 모듈은 skip
        if (self.isExportUsed(module_index, "*")) return;
        try self.markExportUsed(module_index, "*"); // sentinel
        const m = self.modules[module_index];
        for (m.export_bindings) |eb| {
            // re-export 소스 include는 "*" skip 전에 처리
            if (eb.kind == .re_export_all or eb.kind == .re_export) {
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const source_mod = @intFromEnum(m.import_records[rec_idx].resolved);
                        if (source_mod < self.modules.len) {
                            if (!self.included.isSet(source_mod)) self.included.set(source_mod);
                            if (eb.kind == .re_export_all) {
                                try self.markAllExportsUsed(@intCast(source_mod));
                            } else {
                                // named re-export: canonical 모듈도 include
                                if (self.linker.resolveExportChain(
                                    m.import_records[rec_idx].resolved,
                                    eb.local_name,
                                    0,
                                )) |canonical| {
                                    const canon_idx = @intFromEnum(canonical.module_index);
                                    if (canon_idx < self.modules.len) {
                                        if (!self.included.isSet(canon_idx)) self.included.set(canon_idx);
                                        try self.markExportUsed(@intCast(canon_idx), canonical.export_name);
                                    }
                                }
                            }
                        }
                    }
                }
                if (eb.kind == .re_export_all) continue;
            }
            if (std.mem.eql(u8, eb.exported_name, "*")) continue;

            try self.markExportUsed(module_index, eb.exported_name);
        }
    }

    fn hasAnyUsedExport(self: *const TreeShaker, module_index: u32) bool {
        if (module_index >= self.modules.len) return false;
        for (self.modules[module_index].export_bindings) |eb| {
            if (eb.kind == .re_export_all) continue;
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
