//! Import-record reachability and evaluation-preservation helpers.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const Module = @import("../module.zig").Module;
const stmt_info_mod = @import("../stmt_info.zig");
const StmtInfos = stmt_info_mod.ModuleStmtInfos;
const module_effects = @import("module_effects.zig");

pub fn isImportDeclarationStmt(m: *const Module, infos: StmtInfos, stmt_idx: u32) bool {
    if (stmt_idx >= infos.stmts.len) return false;
    const ast = &(m.ast orelse return false);
    const ni: usize = infos.stmts[stmt_idx].node_idx;
    return ni < ast.nodes.items.len and ast.nodes.items[ni].tag == .import_declaration;
}

/// included 모듈의 import_record 가 source 모듈을 evaluation 의존으로 끌어와야 하는지.
/// re-export 는 target 이 evaluation effect 를 갖거나 (side_effects/wrapped/dynamic-fallback),
/// 해당 stmt 가 reachable 일 때만 보존 — `export *` 가 unrelated source 까지 fan out 하지 않도록.
/// side_effect / require / worker / glob / require_context 는 항상 evaluation 의존이라 보존.
/// static_import 만 entry 또는 live binding 이 있을 때만 보존 — dead body 안에서만 참조되는
/// named import 가 source 모듈을 fan out 시키지 않도록. dynamic_import 는 별도
/// dyn_import_targets 경로로 처리되므로 여기선 false.
pub fn shouldPreserveImportRecordForEvaluation(
    self: anytype,
    m: *const Module,
    mod_idx: u32,
    rec_idx: u32,
    live_mod_idx: ?u32,
) !bool {
    if (rec_idx >= m.import_records.len) return false;
    if (m.import_records[rec_idx].kind == .re_export) {
        if (self.graph.getModule(m.import_records[rec_idx].resolved)) |target| {
            if (module_effects.hasEvaluationEffect(target)) return true;
        }
        return try importRecordHasReachableStmt(self, mod_idx, rec_idx);
    }
    if (live_mod_idx == null) return true;
    return switch (m.import_records[rec_idx].kind) {
        .dynamic_import => false,
        .require => try importRecordHasReachableStmt(self, live_mod_idx.?, rec_idx),
        .static_import => self.entry_set.isSet(mod_idx) or importRecordHasLiveBinding(self, m, mod_idx, rec_idx),
        else => true,
    };
}

fn importRecordHasReachableStmt(self: anytype, mod_idx: u32, rec_idx: u32) !bool {
    if (mod_idx >= self.module_stmt_infos.len or mod_idx >= self.reachable_stmts.len) return true;
    const infos = self.module_stmt_infos[mod_idx] orelse return true;
    const reachable = self.reachable_stmts[mod_idx] orelse return false;
    const stmt_indices = (try ensureImportRecordStmtIndices(self, mod_idx, infos)) orelse return false;
    if (rec_idx >= stmt_indices.len) return false;
    const stmt_idx = stmt_indices[rec_idx] orelse return false;
    return reachable.isSet(stmt_idx);
}

pub fn importRecordBelongsToStmt(self: anytype, mod_idx: u32, infos: StmtInfos, stmt_idx: u32, rec_idx: u32) !bool {
    if (stmt_idx >= infos.stmts.len) return false;
    const stmt_indices = (try ensureImportRecordStmtIndices(self, mod_idx, infos)) orelse return false;
    if (rec_idx >= stmt_indices.len) return false;
    return stmt_indices[rec_idx] == stmt_idx;
}

fn ensureImportRecordStmtIndices(self: anytype, mod_idx: u32, infos: StmtInfos) !?[]?u32 {
    const mod_count = self.graph.moduleCount();
    if (mod_idx >= mod_count) return null;
    if (self.import_record_stmt_indices.len == 0) {
        const maps = try self.allocator.alloc(?[]?u32, mod_count);
        for (maps) |*m| m.* = null;
        self.import_record_stmt_indices = maps;
    }
    if (mod_idx >= self.import_record_stmt_indices.len) return null;
    if (self.import_record_stmt_indices[mod_idx] == null) {
        const m = self.graph.getModule(ModuleIndex.fromUsize(mod_idx)) orelse return null;
        const map = try self.allocator.alloc(?u32, m.import_records.len);
        errdefer self.allocator.free(map);
        for (map) |*slot| slot.* = null;
        for (m.import_records, 0..) |rec, rec_i| {
            map[rec_i] = stmt_info_mod.findStmtIndexFromInfos(infos, rec.span.start);
        }
        self.import_record_stmt_indices[mod_idx] = map;
    }
    return self.import_record_stmt_indices[mod_idx].?;
}

/// `isImportLiveInModule` 은 reachable_stmts 미초기화 시 보수적으로 true 를 반환하지만,
/// 이 함수는 "stmt_info 는 빌드됐는데 reachable_stmts 가 비었다 = BFS 가 한 번도 방문 안
/// 한 모듈" 이라 판단해 false 로 정밀화한다. shouldPreserveImportRecordForEvaluation 의
/// static_import 케이스에서만 호출되며, fan-out 보수성을 의도적으로 줄인다.
fn importRecordHasLiveBinding(self: anytype, m: *const Module, mod_idx: u32, rec_idx: u32) bool {
    if (mod_idx < self.module_stmt_infos.len and self.module_stmt_infos[mod_idx] != null) {
        if (mod_idx >= self.reachable_stmts.len or self.reachable_stmts[mod_idx] == null) return false;
    }
    for (m.import_bindings) |ib| {
        if (ib.import_record_index != rec_idx) continue;
        if (self.isImportLiveInModule(mod_idx, ib.local_name)) return true;
    }
    return false;
}
