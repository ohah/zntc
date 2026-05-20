const std = @import("std");
const Module = @import("../module.zig").Module;
const types = @import("../types.zig");
const ImportRecord = types.ImportRecord;
const ModuleIndex = types.ModuleIndex;
const RequestedExports = @import("state.zig").RequestedExports;
const profile = @import("../../profile.zig");

pub fn requestAll(self: anytype, idx: ModuleIndex) !bool {
    if (idx.isNone()) return false;
    const key: u32 = @intFromEnum(idx);
    self.requested_exports_mutex.lock();
    defer self.requested_exports_mutex.unlock();

    const gop = try self.requested_exports.getOrPut(self.allocator, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    if (gop.value_ptr.all) return false;
    gop.value_ptr.names.deinit(self.allocator);
    gop.value_ptr.names = .{};
    gop.value_ptr.all = true;
    return true;
}

pub fn requestNamed(self: anytype, idx: ModuleIndex, name: []const u8) !bool {
    if (idx.isNone()) return false;
    const key: u32 = @intFromEnum(idx);
    self.requested_exports_mutex.lock();
    defer self.requested_exports_mutex.unlock();

    const gop = try self.requested_exports.getOrPut(self.allocator, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    if (gop.value_ptr.all) return false;
    if (gop.value_ptr.names.contains(name)) return false;
    try gop.value_ptr.names.put(self.allocator, name, {});
    return true;
}

/// 이 모듈이 user-declared `sideEffects:false` 인 *순수 re-export barrel* 인지 —
/// `requested_exports` 에 일치하는 record 만 link 하는 정밀 트리쉐이킹 hint 의 적용 대상.
///
/// 순수 barrel 이 아니라 (a) `export class`/`export const x = …` 같은 local 선언이나
/// (b) pre-pass 가 주입한 runtime helper (`__extends` 등) 가 있는 모듈은 `init_<mod>()`
/// 가 그 body 를 실행하면서 자신의 import 를 (helper virtual import 포함) 참조하므로,
/// import record 를 lazy 로 미루면 `export *` chain 으로 번들에 끌려 들어왔을 때 resolve
/// 가 안 돼 emit 에 raw `require("…")` 가 남아 런타임 크래시한다.
pub fn isLazyBarrelCandidate(self: anytype, m: *const Module) bool {
    if (self.dev_mode or self.preserve_modules) return false;
    if (!(m.side_effects_user_defined and
        !m.side_effects and
        m.exports_kind.isEsm() and
        m.import_records.len > 0 and
        m.export_bindings.len > 0)) return false;
    if (m.transform_cache) |tc| if (tc.runtime_helpers.hasAny()) return false;
    return !m.has_local_export;
}

/// Wrapper-barrel pattern: `import x from './w'; export default x;` 같이 imported
/// binding 을 default 로 re-export 하는 lazy_barrel_candidate 의 부분집합. body 가
/// imported binding 을 mutate 할 가능성이 높아 (lodash-es lodash.default.js 의
/// `lodash.uniq = uniq;` 같은 ~300 개 mutation) lazy 처리하면 mutation reference imports
/// 가 누락되어 runtime ReferenceError 발생. graph 의 `shouldLinkResolvedRecordForModule`
/// 와 tree_shaker 의 시드 게이트 양쪽이 이 함수를 사용해 wrapper-barrel 만 정확히
/// 처리하도록 한다. `Module.is_wrapper_barrel` 캐시를 사용해 hot path 중복 계산 회피.
pub fn isWrapperBarrel(self: anytype, m: *const Module) bool {
    if (!isLazyBarrelCandidate(self, m)) return false;
    return m.is_wrapper_barrel;
}

/// `Module.is_wrapper_barrel` / `has_local_export` 캐시를 한 번의 export_bindings 순회로
/// 채운다. graph build 의 `applySideEffects` 직후, parse 가 끝나 export_bindings 가 final
/// 인 시점에 호출.
pub fn computeBarrelFlags(m: *Module) void {
    var is_wrapper = false;
    var has_local = false;
    var default_named_local = false;
    for (m.export_bindings) |eb| {
        if (eb.isDefaultDirectReExport()) is_wrapper = true;
        if (eb.kind == .local) has_local = true;
        if (eb.isNamedLocalDefault()) default_named_local = true;
    }
    m.is_wrapper_barrel = is_wrapper;
    m.has_local_export = has_local;
    m.default_export_named_local = default_named_local;
}

pub fn nameHasDirectNonStarExport(m: *const Module, name: []const u8) bool {
    for (m.export_bindings) |eb| {
        if (eb.kind == .re_export_star) continue;
        if (std.mem.eql(u8, eb.exported_name, name)) return true;
    }
    return false;
}

pub fn shouldLinkResolvedRecordForModule(self: anytype, mod_idx: usize, rec_i: usize, record: ImportRecord) bool {
    const m = self.modules.at(mod_idx);
    switch (record.kind) {
        .side_effect, .require, .dynamic_import, .worker, .glob, .require_context => return true,
        .static_import, .re_export => {},
    }

    if (!isLazyBarrelCandidate(self, m)) return true;
    // Wrapper-barrel pattern 은 body mutation 이 imports 에 의존하므로 lazy 비활성화.
    if (isWrapperBarrel(self, m)) return true;

    const key: u32 = @intCast(mod_idx);
    self.requested_exports_mutex.lock();
    defer self.requested_exports_mutex.unlock();
    const req = self.requested_exports.get(key) orelse return true;
    if (req.all) return true;
    return reExportRecordMatchesRequest(m, rec_i, &req);
}

pub fn shouldResolveRecordForModule(self: anytype, mod_idx: usize, rec_i: usize, record: ImportRecord) bool {
    if (record.resolved != .none or record.is_external) return false;
    return shouldLinkResolvedRecordForModule(self, mod_idx, rec_i, record);
}

pub fn hasDeferredRequestedImports(self: anytype, mod_idx: usize) bool {
    if (mod_idx >= self.modules.count()) return false;
    const m = self.modules.at(mod_idx);
    for (m.import_records, 0..) |record, rec_i| {
        if (shouldResolveRecordForModule(self, mod_idx, rec_i, record)) return true;
    }
    return false;
}

pub fn requestedExportsForReExportRecord(
    self: anytype,
    importer: *const Module,
    rec_i: usize,
    dep_idx: ModuleIndex,
) !bool {
    const importer_key: u32 = @intFromEnum(importer.index);
    var changed = false;

    var requested_names: std.ArrayList([]const u8) = .empty;
    defer requested_names.deinit(self.allocator);

    self.requested_exports_mutex.lock();
    const maybe_req = self.requested_exports.get(importer_key);
    const request_all = if (maybe_req) |req| req.all else true;
    if (!request_all) {
        if (maybe_req) |req| {
            var it = req.names.keyIterator();
            while (it.next()) |name| {
                requested_names.append(self.allocator, name.*) catch {
                    self.requested_exports_mutex.unlock();
                    return error.OutOfMemory;
                };
            }
        }
    }
    self.requested_exports_mutex.unlock();
    if (request_all) return requestAll(self, dep_idx);

    for (requested_names.items) |requested_name| {
        for (importer.export_bindings) |eb| {
            const eb_rec = eb.import_record_index orelse continue;
            if (eb_rec != rec_i) continue;
            switch (eb.kind) {
                .re_export => {
                    if (std.mem.eql(u8, eb.exported_name, requested_name)) {
                        changed = (try requestNamed(self, dep_idx, eb.local_name)) or changed;
                    }
                },
                // namespace / star re-export 는 dep 전체를 요청한다 — 한 번 `.all` 이 되면
                // 이후 requested_name 들의 작업은 전부 no-op 이므로 즉시 반환.
                .re_export_namespace => {
                    if (std.mem.eql(u8, eb.exported_name, requested_name)) {
                        return (try requestAll(self, dep_idx)) or changed;
                    }
                },
                .re_export_star => {
                    // `export * from "./X"` 는 어느 source 가 이 이름을 제공하는지 정적으로
                    // 알 수 없다 — 후보 source 의 namespace 전체를 요청해야 한다. 그러지
                    // 않으면 X 가 이 이름을 안 가졌을 때 X 의 import record 가 deferred 인
                    // 채로 (wrapped barrel 의 `init_*` 로 도달 가능해) 번들에 남아 raw
                    // `require()` 가 출력된다 (#3136).
                    if (!nameHasDirectNonStarExport(importer, requested_name)) {
                        return (try requestAll(self, dep_idx)) or changed;
                    }
                },
                .local => {},
            }
        }
    }
    return changed;
}

pub fn requestDependencyExports(
    self: anytype,
    importer_idx: usize,
    rec_i: usize,
    record: ImportRecord,
    dep_idx: ModuleIndex,
) !bool {
    const importer = self.modules.at(importer_idx);
    switch (record.kind) {
        .static_import => {
            var s = profile.begin(.graph_discover_incr_req_static_import);
            defer s.end();
            var changed = false;
            var found_binding = false;
            for (importer.import_bindings) |ib| {
                if (ib.import_record_index != rec_i) continue;
                found_binding = true;
                switch (ib.kind) {
                    .namespace => changed = (try requestAll(self, dep_idx)) or changed,
                    .default, .named => changed = (try requestNamed(self, dep_idx, ib.imported_name)) or changed,
                }
            }
            if (!found_binding) {
                changed = (try requestAll(self, dep_idx)) or changed;
            }
            return changed;
        },
        .re_export => {
            var s = profile.begin(.graph_discover_incr_req_re_export);
            defer s.end();
            return requestedExportsForReExportRecord(self, importer, rec_i, dep_idx);
        },
        .side_effect, .require, .dynamic_import, .worker, .glob, .require_context => {
            var s = profile.begin(.graph_discover_incr_req_simple);
            defer s.end();
            return requestAll(self, dep_idx);
        },
    }
}

pub fn reExportRecordMatchesRequest(m: *const Module, rec_i: usize, req: *const RequestedExports) bool {
    if (req.all) return true;
    var names = req.names.keyIterator();
    while (names.next()) |requested_name| {
        for (m.export_bindings) |eb| {
            const eb_rec = eb.import_record_index orelse continue;
            if (eb_rec != rec_i) continue;
            switch (eb.kind) {
                .re_export,
                .re_export_namespace,
                => {
                    if (std.mem.eql(u8, eb.exported_name, requested_name.*)) return true;
                },
                .re_export_star => {
                    if (!nameHasDirectNonStarExport(m, requested_name.*)) return true;
                },
                .local => {},
            }
        }
    }
    return false;
}
