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
    var s_mx = profile.begin(.graph_discover_incr_req_mutex);
    self.requested_exports_mutex.lock();
    s_mx.end();
    defer {
        var s_un = profile.begin(.graph_discover_incr_req_mutex);
        self.requested_exports_mutex.unlock();
        s_un.end();
    }

    var s_om = profile.begin(.graph_discover_incr_req_outer_map);
    const gop = try self.requested_exports.getOrPut(self.allocator, key);
    s_om.end();
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    if (gop.value_ptr.all) return false;
    gop.value_ptr.names.deinit(self.allocator);
    gop.value_ptr.names = .empty;
    gop.value_ptr.all = true;
    return true;
}

pub fn requestNamed(self: anytype, idx: ModuleIndex, name: []const u8) !bool {
    if (idx.isNone()) return false;
    const key: u32 = @intFromEnum(idx);
    var s_mx = profile.begin(.graph_discover_incr_req_mutex);
    self.requested_exports_mutex.lock();
    s_mx.end();
    defer {
        var s_un = profile.begin(.graph_discover_incr_req_mutex);
        self.requested_exports_mutex.unlock();
        s_un.end();
    }

    var s_om = profile.begin(.graph_discover_incr_req_outer_map);
    const gop = try self.requested_exports.getOrPut(self.allocator, key);
    s_om.end();
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    if (gop.value_ptr.all) return false;
    var s_ic = profile.begin(.graph_discover_incr_req_inner_contains);
    const already = gop.value_ptr.contains(name);
    s_ic.end();
    if (already) return false;
    var s_ip = profile.begin(.graph_discover_incr_req_inner_put);
    defer s_ip.end();
    try gop.value_ptr.names.append(self.allocator, name);
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

/// `exported_name → export_bindings idx` HashMap 을 build. PR-Y1.
/// computeBarrelFlags 와 동일 시점 (parse 끝나 export_bindings final) 에 호출.
///
/// `resyncAfterAstMutation` 처럼 export_bindings 가 재생성되는 경로에서도 안전하도록,
/// 기존 map 이 있으면 **deinit 후 재build** (stale idx 회피 + 누수 회피). cache-hit
/// 경로는 build_flow 가 cached 쪽 포인터를 nullify 해 ownership 만 이전 (재build X).
///
/// ECMAScript spec: 같은 exported_name 의 중복 export 는 parse-time syntax error 라
/// non-star eb 의 exported_name 은 unique 보장 → fallback 불필요. re_export_star
/// (exported_name="") 는 *어떤* name 도 export 가능해 idx 등록 제외 (caller 가 별도 처리).
pub fn populateExportIndexByName(m: *Module, allocator: std.mem.Allocator) !void {
    if (m.export_index_by_name) |*old| {
        old.deinit(allocator);
        m.export_index_by_name = null;
    }
    if (m.export_bindings.len == 0) return;
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer map.deinit(allocator);
    try map.ensureTotalCapacity(allocator, @intCast(m.export_bindings.len));
    for (m.export_bindings, 0..) |eb, i| {
        if (eb.kind == .re_export_star) continue;
        try map.put(allocator, eb.exported_name, @intCast(i));
    }
    m.export_index_by_name = map;
}

pub fn nameHasDirectNonStarExport(m: *const Module, name: []const u8) bool {
    // PR-Y2: index 가 있으면 O(1) lookup. map 은 non-star eb 만 포함하므로 hit 자체가
    // "non-star export 존재" 증거. populate 안 된 edge (test fixture / asset module) 만
    // linear fallback.
    if (m.export_index_by_name) |map| return map.contains(name);
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
    if (record.resolved != .none or record.is_external or record.resolve_failed) return false;
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
    var s_entry = profile.begin(.graph_discover_incr_re_export_entry);
    const importer_key: u32 = @intFromEnum(importer.index);
    var changed = false;

    // PR-Z1: 매 호출 ArrayList alloc-free (M6 측정 = re_export entry 의 72%, 13.3ms) 회피.
    // re_export importer 의 requested names 는 거의 항상 소수 (수 개 ~ 십수 개) — barrel
    // re-export 의 본질이 "묶음" 이라 caller 가 요청하는 이름 집합도 묶음 이름 일부에 한정.
    // 32-slot stack 으로 흔한 경우 alloc 0, overflow 시 heap ArrayList 로 spillover (rare).
    // stack frame: 32 × 16B = 512B — bundler hot path 용량으로 작음.
    const REQUESTED_NAMES_STACK_CAP = 32;
    var stack_buf: [REQUESTED_NAMES_STACK_CAP][]const u8 = undefined;
    var stack_len: usize = 0;
    var heap_buf: std.ArrayList([]const u8) = .empty;
    defer heap_buf.deinit(self.allocator);
    var overflowed = false;

    self.requested_exports_mutex.lock();
    var s_get = profile.begin(.graph_discover_incr_re_export_entry_get);
    const maybe_req = self.requested_exports.get(importer_key);
    s_get.end();
    const request_all = if (maybe_req) |req| req.all else true;
    if (!request_all) {
        if (maybe_req) |req| {
            var s_copy = profile.begin(.graph_discover_incr_re_export_entry_copy);
            defer s_copy.end();
            // PR-Z2: flat array iter — HashMap.keyIterator 의 bucket scan 회피.
            // 작은 batch (≤ 32) 는 stack-only @memcpy, overflow 시 heap spillover.
            const src = req.names.items;
            if (src.len <= REQUESTED_NAMES_STACK_CAP) {
                @memcpy(stack_buf[0..src.len], src);
                stack_len = src.len;
            } else {
                heap_buf.appendSlice(self.allocator, src) catch {
                    self.requested_exports_mutex.unlock();
                    s_entry.end();
                    return error.OutOfMemory;
                };
                overflowed = true;
            }
        }
    }
    self.requested_exports_mutex.unlock();
    if (request_all) {
        s_entry.end();
        return requestAll(self, dep_idx);
    }
    const requested_names: []const []const u8 = if (overflowed) heap_buf.items else stack_buf[0..stack_len];
    // requested_names 가 비어 있으면 outer 진입 자체가 no-op — star 캐시 계산 회피.
    if (requested_names.len == 0) {
        s_entry.end();
        return changed;
    }

    // PR-Y2: 기존 cross-product O(N×M) 를 O(N) 으로. ECMAScript spec 의 non-star unique
    // 보장으로 (name → idx) HashMap lookup 1회 (M4 결과: 47ms warm 의 66% 차지하는 inner
    // loop). re_export_star 의 rec_i 매치는 outer 진입 전 1회 캐싱 후 outer 마다 boolean.
    var s_star = profile.begin(.graph_discover_incr_re_export_entry_star_scan);
    const has_star_for_rec = blk: {
        for (importer.export_bindings) |eb| {
            if (eb.kind != .re_export_star) continue;
            const eb_rec = eb.import_record_index orelse continue;
            if (eb_rec == rec_i) break :blk true;
        }
        break :blk false;
    };
    s_star.end();
    s_entry.end();

    var s_outer = profile.begin(.graph_discover_incr_re_export_outer);
    defer s_outer.end();
    for (requested_names) |requested_name| {
        // Non-star match: 단일 idx lookup. populate 안 된 edge 는 fallback linear.
        if (importer.export_index_by_name) |map| {
            if (map.get(requested_name)) |eb_idx| {
                const eb = importer.export_bindings[eb_idx];
                if (eb.import_record_index) |eb_rec| {
                    if (eb_rec == rec_i) {
                        switch (eb.kind) {
                            .re_export => {
                                changed = (try requestNamed(self, dep_idx, eb.local_name)) or changed;
                            },
                            .re_export_namespace => {
                                return (try requestAll(self, dep_idx)) or changed;
                            },
                            .local => {},
                            // map 은 non-star 만 포함 → 도달 불가.
                            .re_export_star => unreachable,
                        }
                    }
                }
            }
        } else {
            for (importer.export_bindings) |eb| {
                if (eb.kind == .re_export_star) continue;
                const eb_rec = eb.import_record_index orelse continue;
                if (eb_rec != rec_i) continue;
                if (!std.mem.eql(u8, eb.exported_name, requested_name)) continue;
                switch (eb.kind) {
                    .re_export => {
                        changed = (try requestNamed(self, dep_idx, eb.local_name)) or changed;
                    },
                    .re_export_namespace => {
                        return (try requestAll(self, dep_idx)) or changed;
                    },
                    .local, .re_export_star => {},
                }
            }
        }

        // Star match: `export * from "./X"` 는 어느 source 가 이 이름을 제공하는지 정적으로
        // 알 수 없다 — name 이 non-star 로 직접 export 가 없으면 dep 전체 요청 (#3136).
        if (has_star_for_rec and !nameHasDirectNonStarExport(importer, requested_name)) {
            return (try requestAll(self, dep_idx)) or changed;
        }
    }
    return changed;
}

/// `requestDependencyExports` 의 static_import 경로가 record 마다 `import_bindings` 전체를
/// 선형 스캔하던 것을 제거하기 위한 per-importer CSR 인덱스(record_index → binding 인덱스)를
/// 보장한다. importer 가 바뀔 때만 1회 O(bindings) 재구축하고, `resolveModuleImports` 가 한
/// 모듈의 record 를 연속 처리하므로 전체적으로 O(total bindings) (과거 O(records×bindings)).
/// scatter 는 binding 인덱스 오름차순으로 채워 record 내 원래 순서를 보존 → 출력 byte-identical.
fn ensureBindingsByRecord(self: anytype, importer_idx: usize, importer: *const Module) !void {
    if (self.rdx_cache_owner) |owner| {
        if (owner == importer_idx) return;
    }
    const num_records = importer.import_records.len;
    self.rdx_offsets.clearRetainingCapacity();
    self.rdx_order.clearRetainingCapacity();
    try self.rdx_offsets.appendNTimes(self.allocator, 0, num_records + 1);
    // record 별 binding 개수 → offsets[rec+1] 에 누적
    for (importer.import_bindings) |ib| {
        if (ib.import_record_index < num_records)
            self.rdx_offsets.items[ib.import_record_index + 1] += 1;
    }
    // prefix sum → offsets[rec] = record rec 구간의 시작 위치
    for (1..num_records + 1) |k|
        self.rdx_offsets.items[k] += self.rdx_offsets.items[k - 1];
    const valid_total = self.rdx_offsets.items[num_records];
    try self.rdx_order.appendNTimes(self.allocator, 0, valid_total);
    // counting-sort scatter — cursor 는 offsets 복사본(record 당 다음 쓰기 위치)
    const cursor = try self.allocator.alloc(u32, num_records);
    defer self.allocator.free(cursor);
    @memcpy(cursor, self.rdx_offsets.items[0..num_records]);
    for (importer.import_bindings, 0..) |ib, bi| {
        if (ib.import_record_index < num_records) {
            const rec = ib.import_record_index;
            self.rdx_order.items[cursor[rec]] = @intCast(bi);
            cursor[rec] += 1;
        }
    }
    self.rdx_cache_owner = importer_idx;
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
            // O(records×bindings) → O(bindings): record rec_i 에 속한 binding 만 순회.
            try ensureBindingsByRecord(self, importer_idx, importer);
            if (rec_i + 1 < self.rdx_offsets.items.len) {
                const start = self.rdx_offsets.items[rec_i];
                const end = self.rdx_offsets.items[rec_i + 1];
                for (self.rdx_order.items[start..end]) |bi| {
                    const ib = importer.import_bindings[bi];
                    found_binding = true;
                    switch (ib.kind) {
                        .namespace => changed = (try requestAll(self, dep_idx)) or changed,
                        .default, .named => changed = (try requestNamed(self, dep_idx, ib.imported_name)) or changed,
                    }
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
    if (req.names.items.len == 0) return false;
    // PR-Y2: requestedExportsForReExportRecord 와 동일 패턴 — index lookup O(1) + star check.
    const has_star_for_rec = blk: {
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export_star) continue;
            const eb_rec = eb.import_record_index orelse continue;
            if (eb_rec == rec_i) break :blk true;
        }
        break :blk false;
    };

    for (req.names.items) |requested_name| {
        if (m.export_index_by_name) |map| {
            if (map.get(requested_name)) |eb_idx| {
                const eb = m.export_bindings[eb_idx];
                if (eb.import_record_index) |eb_rec| {
                    if (eb_rec == rec_i) {
                        switch (eb.kind) {
                            .re_export, .re_export_namespace => return true,
                            .local => {},
                            .re_export_star => unreachable,
                        }
                    }
                }
            }
        } else {
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_star) continue;
                const eb_rec = eb.import_record_index orelse continue;
                if (eb_rec != rec_i) continue;
                if (!std.mem.eql(u8, eb.exported_name, requested_name)) continue;
                switch (eb.kind) {
                    .re_export, .re_export_namespace => return true,
                    .local, .re_export_star => {},
                }
            }
        }
        if (has_star_for_rec and !nameHasDirectNonStarExport(m, requested_name)) return true;
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────

const binding_scanner = @import("../binding_scanner.zig");
const ExportBinding = binding_scanner.ExportBinding;
const ImportBinding = binding_scanner.ImportBinding;
const Span = @import("../../lexer/token.zig").Span;

/// `ensureBindingsByRecord` 단위 테스트용 최소 stub — 실제 ModuleGraph 없이
/// CSR 인덱스 필드(+allocator)만 노출. ensureBindingsByRecord 는 self 에서 이 4개와
/// importer 인자만 읽으므로 full graph 불필요.
const RdxStub = struct {
    allocator: std.mem.Allocator,
    rdx_cache_owner: ?usize = null,
    rdx_offsets: std.ArrayListUnmanaged(u32) = .empty,
    rdx_order: std.ArrayListUnmanaged(u32) = .empty,
};

test "ensureBindingsByRecord: record 별 그룹화 + 원래 순서 보존 + 캐시 hit" {
    const testing = std.testing;
    var module = Module.init(@enumFromInt(0), "idx.ts");
    defer module.deinit(testing.allocator);

    // 4 records — Module.deinit 가 record.kind(.require_context) 만 보므로 zeroes(=.static_import) 안전.
    var recs: [4]ImportRecord = undefined;
    for (&recs) |*r| r.* = std.mem.zeroes(ImportRecord);
    module.import_records = &recs;

    // 6 bindings, record 분포: rec0=1(bi3) · rec1=2(bi0,bi2) · rec2=0 · rec3=3(bi1,bi4,bi5).
    // import_record_index 가 뒤섞여 있어 counting-sort scatter 의 순서 보존을 검증.
    const recmap = [_]u32{ 1, 3, 1, 0, 3, 3 };
    const ibs = try testing.allocator.alloc(ImportBinding, recmap.len);
    defer testing.allocator.free(ibs);
    for (ibs, 0..) |*ib, i| {
        ib.* = .{ .kind = .named, .local_name = "x", .imported_name = "x", .local_span = Span.EMPTY, .import_record_index = recmap[i] };
    }
    module.import_bindings = ibs;

    var stub = RdxStub{ .allocator = testing.allocator };
    defer stub.rdx_offsets.deinit(testing.allocator);
    defer stub.rdx_order.deinit(testing.allocator);

    try ensureBindingsByRecord(&stub, 0, &module);

    try testing.expectEqual(@as(?usize, 0), stub.rdx_cache_owner);
    const off = stub.rdx_offsets.items;
    try testing.expectEqual(@as(usize, 5), off.len); // num_records+1
    try testing.expectEqual(@as(u32, 1), off[1] - off[0]); // rec0
    try testing.expectEqual(@as(u32, 2), off[2] - off[1]); // rec1
    try testing.expectEqual(@as(u32, 0), off[3] - off[2]); // rec2 (binding 없음)
    try testing.expectEqual(@as(u32, 3), off[4] - off[3]); // rec3

    const ord = stub.rdx_order.items;
    try testing.expectEqual(@as(u32, 3), ord[off[0]]); // rec0 → bi3
    try testing.expectEqual(@as(u32, 0), ord[off[1]]); // rec1 → bi0 (작은 인덱스 먼저)
    try testing.expectEqual(@as(u32, 2), ord[off[1] + 1]); // rec1 → bi2
    try testing.expectEqual(@as(u32, 1), ord[off[3]]); // rec3 → bi1
    try testing.expectEqual(@as(u32, 4), ord[off[3] + 1]); // rec3 → bi4
    try testing.expectEqual(@as(u32, 5), ord[off[3] + 2]); // rec3 → bi5

    // 같은 importer 재호출 = 재구축 skip(cache hit): 센티넬이 보존되면 clear 안 된 것.
    try stub.rdx_order.append(testing.allocator, 999);
    try ensureBindingsByRecord(&stub, 0, &module);
    try testing.expectEqual(@as(u32, 999), stub.rdx_order.items[stub.rdx_order.items.len - 1]);

    // importer 변경 = 재구축: owner 갱신 + 센티넬 사라짐.
    try ensureBindingsByRecord(&stub, 1, &module);
    try testing.expectEqual(@as(?usize, 1), stub.rdx_cache_owner);
    try testing.expectEqual(@as(usize, recmap.len), stub.rdx_order.items.len); // 999 제거됨
}

test "populateExportIndexByName: 빈 export_bindings 면 null" {
    const testing = std.testing;
    var module = Module.init(@enumFromInt(0), "empty.ts");
    defer module.deinit(testing.allocator);

    try populateExportIndexByName(&module, testing.allocator);
    try testing.expect(module.export_index_by_name == null);
}

test "populateExportIndexByName: re_export_star 는 제외, 나머지는 idx 등록" {
    const testing = std.testing;
    var module = Module.init(@enumFromInt(0), "mix.ts");
    defer module.deinit(testing.allocator);

    const ebs = try testing.allocator.alloc(ExportBinding, 3);
    defer testing.allocator.free(ebs);
    ebs[0] = .{ .exported_name = "a", .local_name = "a", .local_span = Span.EMPTY, .kind = .local };
    ebs[1] = .{ .exported_name = "", .local_name = "", .local_span = Span.EMPTY, .kind = .re_export_star };
    ebs[2] = .{ .exported_name = "b", .local_name = "b_local", .local_span = Span.EMPTY, .kind = .local };
    module.export_bindings = ebs;

    try populateExportIndexByName(&module, testing.allocator);
    const map = &module.export_index_by_name.?;
    try testing.expectEqual(@as(u32, 2), map.count());
    try testing.expectEqual(@as(u32, 0), map.get("a").?);
    try testing.expectEqual(@as(u32, 2), map.get("b").?);
    try testing.expect(map.get("") == null); // re_export_star 의 빈 이름은 등록 안 됨
}

test "populateExportIndexByName: resync 시 stale idx 회피 (재build, 누수 없음)" {
    const testing = std.testing;
    var module = Module.init(@enumFromInt(0), "resync.ts");
    defer module.deinit(testing.allocator);

    // build 1
    var ebs1 = try testing.allocator.alloc(ExportBinding, 2);
    defer testing.allocator.free(ebs1);
    ebs1[0] = .{ .exported_name = "x", .local_name = "x", .local_span = Span.EMPTY, .kind = .local };
    ebs1[1] = .{ .exported_name = "y", .local_name = "y", .local_span = Span.EMPTY, .kind = .local };
    module.export_bindings = ebs1;
    try populateExportIndexByName(&module, testing.allocator);
    try testing.expectEqual(@as(u32, 0), module.export_index_by_name.?.get("x").?);
    try testing.expectEqual(@as(u32, 1), module.export_index_by_name.?.get("y").?);

    // resync: export_bindings 가 재생성돼 idx 가 바뀌었다고 가정 (x, y 의 순서 swap)
    const ebs2 = try testing.allocator.alloc(ExportBinding, 2);
    defer testing.allocator.free(ebs2);
    ebs2[0] = .{ .exported_name = "y", .local_name = "y", .local_span = Span.EMPTY, .kind = .local };
    ebs2[1] = .{ .exported_name = "x", .local_name = "x", .local_span = Span.EMPTY, .kind = .local };
    module.export_bindings = ebs2;
    try populateExportIndexByName(&module, testing.allocator);
    // 재build 되어 새 idx 가 반영되어야 함 (stale 0/1 가 아닌 1/0).
    try testing.expectEqual(@as(u32, 1), module.export_index_by_name.?.get("x").?);
    try testing.expectEqual(@as(u32, 0), module.export_index_by_name.?.get("y").?);
}
