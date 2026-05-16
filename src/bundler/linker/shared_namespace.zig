//! Shared namespace object generation for linker metadata.
//!
//! Namespace import/re-export metadata needs both member-access rewrites and,
//! when the namespace is used as a value, an object preamble. This module owns
//! those caches and preamble declarations while `linker.zig` keeps export
//! resolution and symbol population.

const std = @import("std");
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const LinkingMetadata = linker_mod.LinkingMetadata;
const ModuleIndex = @import("../types.zig").ModuleIndex;
const CompiledModule = @import("../compiled_module.zig").CompiledModule;
const Module = @import("../module.zig").Module;
const rt = @import("../runtime_helpers.zig");
const profile = @import("../../profile.zig");
const debug_log = @import("../../debug_log.zig");

const NsExportPair = Linker.NsExportPair;
const SharedNsInline = Linker.SharedNsInline;
const max_chain_depth = 100;

/// 모듈의 중첩 스코프 (비-모듈 스코프) 에 해당 이름이 존재하는지 확인.
/// linker.zig 의 method 와 동일.
fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
    const m = self.getModule(module_index) orelse return false;
    const sem = m.semantic orelse return false;
    for (sem.scope_maps, 0..) |scope_map, scope_idx| {
        if (scope_idx == 0) continue;
        if (scope_map.get(name) != null) return true;
    }
    return false;
}

/// ESM namespace import를 위한 namespace 객체 preamble 생성.
/// namespace import/re-export에 대해 ns_member_rewrites + ns_inline_objects를 등록.
/// buildMetadataForAst 내 3곳에서 동일 패턴을 공유. 캐시는 linker 전역
/// (`self.ns_export_cache` / `self.ns_inline_cache`) — 같은 target 을 여러
/// importer 가 namespace import 할 때 collectExportsRecursive DFS 를 단 한 번만 수행.
///
/// `force_inline`: caller 가 isNamespaceUsedAsValue / exported_locals 등으로 결정한
/// 강제 inline 신호. shadow 충돌은 함수 안에서 자체 감지하여 ns_inline_list 를 활성화.
pub fn registerNamespaceRewrites(
    self: *const Linker,
    ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
    ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
    owned_rewrite_values: *std.ArrayListUnmanaged([]const u8),
    /// 같은 importer 안에서 여러 namespace import 가 같은 target source 의 inline ns_var
    /// 를 공유하도록 caller 가 owned. `cjs_var_cache` 와 같은 패턴 (`metadata.zig`).
    ns_target_to_var: *std.AutoHashMap(u32, []const u8),
    force_inline: bool,
    importer_mod_idx: u32,
    symbol_id: u32,
    target_mod_idx: u32,
    var_name: []const u8,
) std.mem.Allocator.Error!void {
    var scope = profile.begin(.metadata_register_ns_rewrites);
    defer scope.end();

    const mutable_self = @constCast(self);

    // Fast path: lock 으로 캐시 조회. 히트 시 즉시 반환, 미스 시 lock 밖에서 DFS 수행 후
    // double-check 로 put. DFS 자체는 lock 밖 — 다른 스레드가 먼저 같은 target 을
    // 계산할 경우 중복 수행되지만 최종적으로 하나만 캐시에 남음 (두 번째는 폐기).
    mutable_self.ns_cache_mutex.lock();
    const cache_hit: ?[]NsExportPair = self.ns_export_cache.get(target_mod_idx);
    mutable_self.ns_cache_mutex.unlock();

    const cached_exports = if (cache_hit) |cached| cached else blk: {
        var exports: std.ArrayList(NsExportPair) = .empty;
        // 에러 시에만 정리 — 정상 경로에서는 캐시로 소유권 이동
        errdefer {
            for (exports.items) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            exports.deinit(self.allocator);
        }
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();
        // double-check: 다른 스레드가 먼저 put 했을 수 있음 — 내 계산 폐기
        if (self.ns_export_cache.get(target_mod_idx)) |raced| {
            for (exports.items) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            exports.deinit(self.allocator);
            break :blk raced;
        }
        const owned_slice = try self.allocator.dupe(NsExportPair, exports.items);
        exports.deinit(self.allocator);
        try mutable_self.ns_export_cache.put(self.allocator, target_mod_idx, owned_slice);
        break :blk owned_slice;
    };

    var seen_exports = std.StringHashMap(void).init(self.allocator);
    defer seen_exports.deinit();
    for (cached_exports) |exp| {
        try seen_exports.put(exp.exported, {});
    }

    // importer 의 nested binding 과 충돌하는 export 는 inline 시 self-shadow 무한
    // 재귀 위험 → 매핑 등록을 건너뛰고 has_shadow 로 추적.
    // (예: `const setSelectedLog = (i) => LogBoxData.setSelectedLog(i);` 가
    //  `const setSelectedLog = (i) => setSelectedLog(i);` 로 inline 되는 케이스)
    //
    // 또한 ns_target_mod 가 있는 export (re_export_namespace 등) 는 target_mod 별
    // hoisted ns_var 를 만들고 inner_map 매핑은 그 변수명으로 둔다 — emitStaticMember
    // 가 access site 마다 객체 literal 을 inline emit 하는 회귀 방지 (#1928).
    var inner_map = std.StringHashMap([]const u8).init(self.allocator);
    var inner_map_transferred = false;
    errdefer if (!inner_map_transferred) inner_map.deinit();
    var has_shadow = false;
    // target_init 은 target_mod_idx 에만 의존하므로 export 마다 재계산할 필요가 없다.
    // 비-dev 빌드는 wrap 자체가 불필요하므로 호출도 생략한다 (lazy 런타임 미사용).
    const target_init: ?[]const u8 = if (self.dev_mode)
        try allocEsmInitExprForModuleIndex(self, target_mod_idx)
    else
        null;
    defer if (target_init) |expr| self.allocator.free(expr);
    // barrel re-export (`export { a, b, c } from './x'`) 에서 같은 source_mod_idx 가
    // export 마다 반복 → 매번 `allocEsmInitExprForModuleIndex` 가 동일한 init 식을 새로
    // alloc. 호출자가 owned 한 캐시로 1회 alloc + 재사용. null 결과 (source.wrap_kind
    // != .esm) 도 캐시해 이중 lookup 회피. 같은 패턴: `cjs_var_cache` (metadata.zig).
    var source_init_cache = std.AutoHashMap(u32, ?[]const u8).init(self.allocator);
    defer {
        var it = source_init_cache.valueIterator();
        while (it.next()) |value_ptr| {
            if (value_ptr.*) |expr| self.allocator.free(expr);
        }
        source_init_cache.deinit();
    }
    for (cached_exports) |exp| {
        if (hasNestedBinding(self, importer_mod_idx, exp.exported)) {
            has_shadow = true;
            continue;
        }
        if (exp.ns_target_mod) |target| {
            const ns_var = if (ns_target_to_var.get(target)) |cached|
                cached
            else blk: {
                if (self.useSharedNsInline(target)) {
                    const ns_var_name = try appendSharedNsInlineEntry(self, ns_inline_list, null, target, &seen_exports);
                    try ns_target_to_var.put(target, ns_var_name);
                    break :blk ns_var_name;
                }
                const fresh = try makeUniqueNsVarName(self, exp.exported, &seen_exports);
                try ns_target_to_var.put(target, fresh);
                const obj_str = try buildInlineObjectStr(self, target, 0);
                try ns_inline_list.append(self.allocator, .{
                    .symbol_id = null,
                    .object_literal = obj_str,
                    .var_name = fresh,
                });
                break :blk fresh;
            };
            // inner_map 은 ns_inline_list.entry.var_name pointer 를 borrow — ns_inline
            // 이 owner. inner_map.deinit 은 backing 만 해제, value pointer 는 안 건드림 →
            // 같은 메모리 double-free 없음.
            try inner_map.put(exp.exported, ns_var);
            continue;
        }
        if (self.dev_mode) {
            if (try allocNamespaceMemberRewriteValue(self, target_init, target_mod_idx, exp, &source_init_cache)) |rewrite_value| {
                var owned_by_list = false;
                errdefer if (!owned_by_list) self.allocator.free(rewrite_value);
                // ns_member_rewrites map 은 포인터만 빌리고, 실제 소유권은
                // LinkingMetadata.owned_rename_values 로 이전해 metadata deinit 에서 해제한다.
                try owned_rewrite_values.append(self.allocator, rewrite_value);
                owned_by_list = true;
                try inner_map.put(exp.exported, rewrite_value);
                continue;
            }
        }
        // exp.local 은 owned=true 면 ns_export_cache 가, 아니면 target module 이 소유한다.
        // metadata map 은 값 포인터만 빌린다.
        try inner_map.put(exp.exported, exp.local);
    }
    try ns_rewrite_list.append(self.allocator, .{
        .symbol_id = symbol_id,
        .map = inner_map,
    });
    inner_map_transferred = true;

    // ns_inline_list 활성화 조건: caller 가 명시 (force_inline) 또는 shadow 충돌 발생.
    // 후자의 경우 codegen fallback 이 namespace 객체 access 로 emit 할 수 있도록 객체가 필요.
    if (force_inline or has_shadow) {
        if (self.useSharedNsInline(target_mod_idx)) {
            _ = try appendSharedNsInlineEntry(self, ns_inline_list, symbol_id, target_mod_idx, &seen_exports);
        } else {
            const obj_str = try buildInlineObjectStr(self, target_mod_idx, 0);
            const ns_var_name = try makeUniqueNsVarName(self, var_name, &seen_exports);
            try ns_inline_list.append(self.allocator, .{
                .symbol_id = symbol_id,
                .object_literal = obj_str,
                .var_name = ns_var_name,
            });
        }
    }
}

/// cross-chunk namespace re-export 배선용: target 의 shared ns 객체 변수를
/// **선제 materialize**하고 이름을 반환. computeCrossChunkLinks 가 namespace
/// 메타데이터(registerNamespaceRewrites)보다 먼저 도므로, 그 시점엔 shared
/// 캐시가 비어 ns-var 이름을 알 수 없다(#3321 후속 timing seam). 여기서
/// 캐시·ns_shared_inline_order 를 채우면 (1) appendSharedNamespacePreambleFiltered
/// 가 정의자 청크에 `var <ns_var>={...}` 를 emit 하고 (2) 이후 metadata 의
/// getOrCreateSharedNamespaceVar 가 cache-hit 으로 같은 이름을 재사용한다.
/// idempotent — 같은 target 재호출은 캐시 반환.
pub fn ensureSharedNsVar(
    self: *const Linker,
    target: ModuleIndex,
) std.mem.Allocator.Error![]const u8 {
    const target_mod_idx = target.toU32();
    // 캐시 fast-path: computeCrossChunkLinks/emit 의 청크×모듈 루프에서
    // 같은 target 이 반복 호출된다. 히트 시 DFS·seen_exports 빌드를 통째로
    // 생략 (getOrCreateSharedNamespaceVar 는 seen_exports 를 신규 이름
    // 발급에만 쓰므로 캐시 히트면 불필요).
    {
        const mutable_self = @constCast(self);
        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();
        if (self.ns_shared_inline_cache.get(target_mod_idx)) |cached| return cached.var_name;
    }
    var exports: std.ArrayList(NsExportPair) = .empty;
    var seen = std.StringHashMap(void).init(self.allocator);
    var visited = std.AutoHashMap(u32, void).init(self.allocator);
    defer {
        for (exports.items) |e| if (e.owned) self.allocator.free(e.local);
        exports.deinit(self.allocator);
        seen.deinit();
        visited.deinit();
    }
    try self.collectExportsRecursive(&exports, &seen, &visited, target, 0);
    var seen_exports = std.StringHashMap(void).init(self.allocator);
    defer seen_exports.deinit();
    for (exports.items) |e| try seen_exports.put(e.exported, {});
    return getOrCreateSharedNamespaceVar(self, target_mod_idx, &seen_exports);
}

/// shared namespace cache 에 declaration-only entry 추가. `getOrCreateSharedNamespaceVar`
/// 로 청크-glob 한 var name 발급 + ns_inline_list 에 빈 object_literal 로 등록 (실 literal
/// 은 ns_shared_inline_cache 가 보유, 청크 emit 단계가 정의자 청크 preamble 로 inline).
/// 반환값은 var name — caller 가 inner_map 등에 사용.
fn appendSharedNsInlineEntry(
    self: *const Linker,
    ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
    symbol_id: ?u32,
    target_mod_idx: u32,
    seen_exports: *std.StringHashMap(void),
) std.mem.Allocator.Error![]const u8 {
    const ns_var_name = try getOrCreateSharedNamespaceVar(self, target_mod_idx, seen_exports);
    try ns_inline_list.append(self.allocator, .{
        .symbol_id = symbol_id,
        .object_literal = try self.allocator.dupe(u8, ""),
        .var_name = try self.allocator.dupe(u8, ns_var_name),
        .shared_target_mod_idx = target_mod_idx,
    });
    return ns_var_name;
}

fn getOrCreateSharedNamespaceVar(
    self: *const Linker,
    target_mod_idx: u32,
    seen_exports: *std.StringHashMap(void),
) std.mem.Allocator.Error![]const u8 {
    const mutable_self = @constCast(self);

    mutable_self.ns_cache_mutex.lock();
    if (self.ns_shared_inline_cache.get(target_mod_idx)) |cached| {
        mutable_self.ns_cache_mutex.unlock();
        return cached.var_name;
    }
    mutable_self.ns_cache_mutex.unlock();

    const object_literal = try buildInlineObjectStr(self, target_mod_idx, 0);
    errdefer self.allocator.free(object_literal);
    const base_name = try makeSharedNamespaceBaseName(self, target_mod_idx);
    defer self.allocator.free(base_name);

    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();

    if (self.ns_shared_inline_cache.get(target_mod_idx)) |raced| {
        self.allocator.free(object_literal);
        return raced.var_name;
    }

    const fresh = try makeUniqueSharedNsVarNameLocked(mutable_self, base_name, seen_exports);
    errdefer self.allocator.free(fresh);
    try mutable_self.ns_shared_inline_order.append(self.allocator, target_mod_idx);
    errdefer _ = mutable_self.ns_shared_inline_order.pop();
    try mutable_self.ns_shared_inline_cache.put(self.allocator, target_mod_idx, .{
        .var_name = fresh,
        .object_literal = object_literal,
    });
    try mutable_self.ns_shared_var_names.put(self.allocator, fresh, {});
    return fresh;
}

pub fn appendSharedNamespacePreamble(self: *const Linker, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    try appendSharedNamespacePreambleFiltered(self, out, null);
}

/// 특정 청크의 정의자 모듈에 속한 namespace 만 emit. `target_filter` 가 non-null 이면
/// 그 set 에 속한 target_mod_idx 만 inline — splitting / manualChunks 시 referrer
/// 청크가 아닌 정의자 청크의 preamble 에 namespace 가 위치하도록 한다.
/// null 이면 전 namespace inline (single-file bundle 호환).
pub fn appendSharedNamespacePreambleFiltered(
    self: *const Linker,
    out: *std.ArrayList(u8),
    target_filter: ?*const std.AutoHashMapUnmanaged(u32, void),
) std.mem.Allocator.Error!void {
    const sorted_targets = try self.allocator.dupe(u32, self.ns_shared_inline_order.items);
    defer self.allocator.free(sorted_targets);
    const SortCtx = struct {
        linker: *const Linker,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            const ap = if (ctx.linker.getModule(a)) |m| m.path else "";
            const bp = if (ctx.linker.getModule(b)) |m| m.path else "";
            const order = std.mem.order(u8, ap, bp);
            if (order != .eq) return order == .lt;
            return a < b;
        }
    };
    std.mem.sort(u32, sorted_targets, SortCtx{ .linker = self }, SortCtx.lessThan);

    // G1-step2: 첫 arrow 변환 entry 직전에 helper 를 같은 buffer (preamble) 맨 앞쪽에
    // lazy emit — `$x(V,{...})` 사용처보다 물리적으로 먼저 정의되어 emit-order 무관.
    // helper 본문은 canonical `rt.EXPORT_RUNTIME_*_MIN` 재사용 (3rd copy drift 방지) +
    // configurable variant 로 RN/Hermes 의 `configurable:true` 보존. `$x`/`$dp` 는
    // NAMES 등록 이름이라 mangler-safe; esm-wrap 가 같은 variant 를 정의해도 `var`
    // 재선언 + 동일 본문이라 무해.
    var helper_emitted = false;
    for (sorted_targets) |target_mod_idx| {
        if (target_filter) |f| {
            if (!f.contains(target_mod_idx)) continue;
        }
        const entry = self.ns_shared_inline_cache.get(target_mod_idx) orelse continue;
        if (self.minify_whitespace) {
            if (try tryRewriteGetterObjToArrowExport(self.allocator, entry.object_literal)) |arrow_map| {
                defer self.allocator.free(arrow_map);
                if (!helper_emitted) {
                    try out.appendSlice(self.allocator, "var " ++ rt.NAMES.DEF_PROP_MIN ++ "=Object.defineProperty;");
                    try out.appendSlice(self.allocator, if (self.configurable_exports)
                        rt.EXPORT_RUNTIME_CONFIGURABLE_MIN
                    else
                        rt.EXPORT_RUNTIME_MIN);
                    try out.appendSlice(self.allocator, "\n");
                    helper_emitted = true;
                }
                try out.appendSlice(self.allocator, "var ");
                try out.appendSlice(self.allocator, entry.var_name);
                try out.appendSlice(self.allocator, "={};");
                try out.appendSlice(self.allocator, rt.NAMES.EXPORT_MIN);
                try out.appendSlice(self.allocator, "(");
                try out.appendSlice(self.allocator, entry.var_name);
                try out.appendSlice(self.allocator, ",");
                try out.appendSlice(self.allocator, arrow_map);
                try out.appendSlice(self.allocator, ");\n");
                continue;
            }
        }
        try out.appendSlice(self.allocator, "var ");
        try out.appendSlice(self.allocator, entry.var_name);
        try out.appendSlice(self.allocator, " = ");
        try out.appendSlice(self.allocator, entry.object_literal);
        try out.appendSlice(self.allocator, ";\n");
        // 큰 namespace inline 의 size 영향 측정. `get NAME(){return VAL}` 패턴은
        // esbuild/rolldown 의 `NAME:()=>VAL` arrow `__export` 보다 per-export ~9 byte 큼
        // (~9 exports 부터 helper 패턴이 더 짧음). 어느 라이브러리에서 격차가 큰지
        // 식별용 — export count 는 `get ` prefix 개수로 근사.
        if (debug_log.enabled(.ns_inline_audit)) {
            const literal = entry.object_literal;
            const export_count = std.mem.count(u8, literal, "get ");
            debug_log.print(.ns_inline_audit, "  - {s}: exports={d} bytes={d}\n", .{
                entry.var_name,
                export_count,
                literal.len,
            });
        }
    }
}

/// G1-step2: export 개수 임계 — 미만이면 helper 고정비용(~84B)이 절감을 못 넘는다.
const ARROW_EXPORT_MIN = 9;

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// minify_whitespace getter object `{get a(){return x},get "b"(){return f(y)}}`
/// → arrow export map `{a:()=>x,"b":()=>f(y)}` (caller 가 `var V={};$x(V,<map>)`).
/// 순수 getter object (모든 멤버 `get NAME(){return VAL}`) + export ≥ ARROW_EXPORT_MIN
/// 일 때만 성공. nested re-export (`NAME:{...}`) 등 다른 형태 1개라도 섞이면 null
/// (getter object 유지). 우리 codegen 이 생성한 deterministic 형식 전제 — VAL 안의
/// string/template 만 상태 추적, 그 외는 depth-balance (zod 검증).
fn tryRewriteGetterObjToArrowExport(
    allocator: std.mem.Allocator,
    obj: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    if (obj.len < 2 or obj[0] != '{' or obj[obj.len - 1] != '}') return null;
    var result: std.ArrayList(u8) = .empty;
    // `return null` 과 error(`try`) 양쪽 모두 ok=false 상태 → 단일 defer 로 정리.
    // 성공 시에만 ok=true 로 소유권 이전 (toOwnedSlice).
    var ok = false;
    defer if (!ok) result.deinit(allocator);
    try result.append(allocator, '{');
    var i: usize = 1;
    var count: usize = 0;
    const end = obj.len - 1; // 마지막 `}` 제외
    while (i < end) {
        if (!std.mem.startsWith(u8, obj[i..], "get ")) return null;
        i += 4;
        const name_start = i;
        if (i < end and obj[i] == '"') {
            i += 1;
            while (i < end and obj[i] != '"') : (i += 1) {
                if (obj[i] == '\\') i += 1;
            }
            if (i >= end) return null;
            i += 1; // closing "
        } else {
            while (i < end and isIdentChar(obj[i])) : (i += 1) {}
        }
        if (i == name_start) return null;
        const name = obj[name_start..i];
        if (!std.mem.startsWith(u8, obj[i..], "(){return ")) return null;
        i += 10;
        const val_start = i;
        var depth: usize = 0;
        var in_str: u8 = 0;
        while (i < obj.len) : (i += 1) {
            const c = obj[i];
            if (in_str != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (c == in_str) {
                    in_str = 0;
                }
                continue;
            }
            switch (c) {
                '"', '\'', '`' => in_str = c,
                '(', '[', '{' => depth += 1,
                ')', ']' => {
                    if (depth == 0) return null;
                    depth -= 1;
                },
                '}' => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                else => {},
            }
        }
        if (i >= obj.len or obj[i] != '}') return null;
        const val = obj[val_start..i];
        if (val.len == 0) return null;
        i += 1; // skip getter close `}`
        if (count > 0) try result.append(allocator, ',');
        try result.appendSlice(allocator, name);
        try result.appendSlice(allocator, ":()=>");
        // VAL 이 `{` 로 시작하면 arrow body 가 block 으로 오파싱 (`()=>{k:1}` 은
        // label statement). object literal 반환은 paren 필수 — `()=>({k:1})`.
        const wrap_obj = val[0] == '{';
        if (wrap_obj) try result.append(allocator, '(');
        try result.appendSlice(allocator, val);
        if (wrap_obj) try result.append(allocator, ')');
        count += 1;
        if (i < end) {
            if (obj[i] != ',') return null;
            i += 1;
        }
    }
    if (count < ARROW_EXPORT_MIN) return null;
    try result.append(allocator, '}');
    ok = true;
    return try result.toOwnedSlice(allocator);
}

pub fn restoreSharedNamespaceDecls(self: *const Linker, decls: []const CompiledModule.SharedNsDecl) std.mem.Allocator.Error!void {
    const mutable_self = @constCast(self);
    for (decls) |decl| {
        const target_idx = self.graph.path_to_module.get(decl.target_path) orelse continue;
        const target_mod_idx = @intFromEnum(target_idx);

        mutable_self.ns_cache_mutex.lock();
        if (self.ns_shared_inline_cache.get(target_mod_idx) != null) {
            mutable_self.ns_cache_mutex.unlock();
            continue;
        }
        mutable_self.ns_cache_mutex.unlock();

        const owned_var = try self.allocator.dupe(u8, decl.var_name);
        errdefer self.allocator.free(owned_var);
        const owned_obj = try self.allocator.dupe(u8, decl.object_literal);
        errdefer self.allocator.free(owned_obj);

        mutable_self.ns_cache_mutex.lock();
        defer mutable_self.ns_cache_mutex.unlock();
        if (self.ns_shared_inline_cache.get(target_mod_idx) != null) {
            self.allocator.free(owned_var);
            self.allocator.free(owned_obj);
            continue;
        }
        if (self.ns_shared_var_names.contains(owned_var)) {
            self.allocator.free(owned_var);
            self.allocator.free(owned_obj);
            continue;
        }
        try mutable_self.ns_shared_inline_order.append(self.allocator, target_mod_idx);
        errdefer _ = mutable_self.ns_shared_inline_order.pop();
        try mutable_self.ns_shared_inline_cache.put(self.allocator, target_mod_idx, .{
            .var_name = owned_var,
            .object_literal = owned_obj,
        });
        try mutable_self.ns_shared_var_names.put(self.allocator, owned_var, {});
    }
}

pub fn collectSharedNamespaceDecls(
    self: *const Linker,
    allocator: std.mem.Allocator,
    md: *const LinkingMetadata,
) std.mem.Allocator.Error![]const CompiledModule.SharedNsDecl {
    var decls: std.ArrayList(CompiledModule.SharedNsDecl) = .empty;
    errdefer {
        for (decls.items) |d| {
            allocator.free(d.target_path);
            allocator.free(d.var_name);
            allocator.free(d.object_literal);
        }
        decls.deinit(allocator);
    }

    var seen = std.AutoHashMap(u32, void).init(allocator);
    defer seen.deinit();

    for (md.ns_inline_objects.entries) |entry| {
        const target_mod_idx = entry.shared_target_mod_idx orelse continue;
        if (seen.contains(target_mod_idx)) continue;
        try seen.put(target_mod_idx, {});

        const target = self.getModule(target_mod_idx) orelse continue;
        @constCast(self).ns_cache_mutex.lock();
        const shared_copy = if (self.ns_shared_inline_cache.get(target_mod_idx)) |shared| SharedNsInline{
            .var_name = shared.var_name,
            .object_literal = shared.object_literal,
        } else null;
        @constCast(self).ns_cache_mutex.unlock();
        const shared = shared_copy orelse continue;

        const target_path = try allocator.dupe(u8, target.path);
        errdefer allocator.free(target_path);
        const var_name = try allocator.dupe(u8, shared.var_name);
        errdefer allocator.free(var_name);
        const object_literal = try allocator.dupe(u8, shared.object_literal);
        errdefer allocator.free(object_literal);

        try decls.append(allocator, .{
            .target_path = target_path,
            .var_name = var_name,
            .object_literal = object_literal,
        });
    }

    return decls.toOwnedSlice(allocator);
}

fn makeSharedNamespaceBaseName(self: *const Linker, target_mod_idx: u32) std.mem.Allocator.Error![]const u8 {
    const target = self.getModule(target_mod_idx) orelse return self.allocator.dupe(u8, "ns");
    const basename = std.fs.path.basename(target.path);
    const without_ext = if (std.mem.lastIndexOf(u8, basename, ".")) |dot| basename[0..dot] else basename;

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(self.allocator);
    if (without_ext.len == 0 or !(std.ascii.isAlphabetic(without_ext[0]) or without_ext[0] == '_' or without_ext[0] == '$')) {
        try buf.append(self.allocator, '_');
    }
    for (without_ext) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
            try buf.append(self.allocator, c);
        } else {
            try buf.append(self.allocator, '_');
        }
    }
    return buf.toOwnedSlice(self.allocator);
}

fn makeUniqueSharedNsVarNameLocked(
    self: *Linker,
    base: []const u8,
    seen_exports: *std.StringHashMap(void),
) std.mem.Allocator.Error![]const u8 {
    var candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns", .{base});
    if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;

    var i: usize = 2;
    while (true) : (i += 1) {
        self.allocator.free(candidate);
        candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns_{d}", .{ base, i });
        if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;
    }
}

/// namespace preamble 변수명을 export 이름과 충돌하지 않도록 생성.
/// "z" → "z_ns", 충돌 시 "z_ns2", "z_ns3", ...
fn makeUniqueNsVarName(self: *const Linker, base: []const u8, exports: *const std.StringHashMap(void)) std.mem.Allocator.Error![]const u8 {
    // 첫 시도: base_ns
    const first = try std.mem.concat(self.allocator, u8, &.{ base, "_ns" });
    if (!exports.contains(first)) return first;
    self.allocator.free(first);

    // 충돌 시 progressive suffix: base_ns2, base_ns3, ...
    // export 수가 유한하므로 반드시 종료
    var suffix: u32 = 2;
    while (true) : (suffix += 1) {
        var buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{suffix}) catch unreachable;
        const candidate = try std.mem.concat(self.allocator, u8, &.{ base, "_ns", num_str });
        if (!exports.contains(candidate)) return candidate;
        self.allocator.free(candidate);
    }
}

/// 모듈의 모든 export를 인라인 객체 문자열로 생성 (재귀적).
/// `export * as ns` export는 소스 모듈의 인라인 객체로 중첩.
/// 결과는 `self.ns_inline_cache` 에 target_mod_idx 별로 캐싱 — linker 전역 공유.
fn buildInlineObjectStr(
    self: *const Linker,
    target_mod_idx: u32,
    depth: u32,
) std.mem.Allocator.Error![]const u8 {
    if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
    const target_any = self.getModule(target_mod_idx) orelse
        return try self.allocator.dupe(u8, "{}");

    const mutable_self = @constCast(self);

    // 캐시 히트: 복사본 반환 (호출자가 소유권을 가짐)
    mutable_self.ns_cache_mutex.lock();
    const cache_hit = self.ns_inline_cache.get(target_mod_idx);
    mutable_self.ns_cache_mutex.unlock();
    if (cache_hit) |cached_str| {
        return try self.allocator.dupe(u8, cached_str);
    }

    var exports: std.ArrayList(NsExportPair) = .empty;
    defer {
        for (exports.items) |exp| {
            if (exp.owned) self.allocator.free(exp.local);
        }
        exports.deinit(self.allocator);
    }
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var visited = std.AutoHashMap(u32, void).init(self.allocator);
    defer visited.deinit();
    try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

    // export * as ns 패턴 수집 (별도 처리 — 재귀 인라인 필요)
    const target = target_any;
    var ns_re_exports = std.StringHashMap(u32).init(self.allocator); // exported_name → source_mod
    defer ns_re_exports.deinit();
    for (target.export_bindings) |eb| {
        if (eb.kind == .re_export_namespace) {
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < target.import_records.len) {
                    const src = target.import_records[rec_idx].resolved;
                    if (!src.isNone()) {
                        try ns_re_exports.put(eb.exported_name, @intFromEnum(src));
                    }
                }
            }
        }
    }

    // getter 객체 생성 (Rolldown 호환): { get prop() { return local; } }
    // 값 복사 대신 getter를 사용하여 live binding을 보존한다.
    // circular dep에서 init 시점에 아직 undefined인 변수도 사용 시점에 올바르게 참조.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    // minify_whitespace 모드 토큰 — getter 패턴의 ` ` 와 `; ` 를 제거.
    // `get foo() { return bar; }` (30c) → `get foo(){return bar}` (24c).
    // 1699 getter 가 있는 effect 번들에서 ~10KB 절감.
    const min_ws = self.minify_whitespace;
    const list_sep: []const u8 = if (min_ws) "," else ", ";
    const colon_sep: []const u8 = if (min_ws) ":" else ": ";
    const get_open: []const u8 = if (min_ws) "(){return " else "() { return ";
    const get_close: []const u8 = if (min_ws) "}" else "; }";
    try buf.appendSlice(self.allocator, "{");
    var first = true;
    for (exports.items) |exp| {
        // declaration 이 tree-shaken 되어 emit 안 되면 namespace getter 도 skip —
        // dangling reference 방지. declaration 모듈은 init_mod (lazy init) 있으면
        // 그쪽, 없으면 target (정적 export).
        const decl_mod_idx = exp.init_mod orelse target_mod_idx;
        if (self.graph.getModule(@enumFromInt(decl_mod_idx))) |decl_mod| {
            if (!decl_mod.isLocalBindingAlive(exp.local)) continue;
        }
        if (!first) try buf.appendSlice(self.allocator, list_sep);
        first = false;
        const needs_quote = needsPropertyQuoteForExport(exp.exported);
        // export * as ns 패턴이면 재귀 인라인 (값으로 참조)
        if (ns_re_exports.get(exp.exported)) |src_mod| {
            if (needs_quote) {
                try buf.appendSlice(self.allocator, "\"");
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, "\"");
            } else {
                try buf.appendSlice(self.allocator, exp.exported);
            }
            try buf.appendSlice(self.allocator, colon_sep);
            const nested = try buildInlineObjectStr(self, src_mod, depth + 1);
            defer self.allocator.free(nested);
            try buf.appendSlice(self.allocator, nested);
        } else {
            // getter: get prop() { return local; }
            try buf.appendSlice(self.allocator, "get ");
            if (needs_quote) {
                try buf.appendSlice(self.allocator, "\"");
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, "\"");
            } else {
                try buf.appendSlice(self.allocator, exp.exported);
            }
            try buf.appendSlice(self.allocator, get_open);
            if (try allocNamespaceGetterValue(self, exp)) |value| {
                defer self.allocator.free(value);
                try buf.appendSlice(self.allocator, value);
            } else {
                try buf.appendSlice(self.allocator, exp.local);
            }
            try buf.appendSlice(self.allocator, get_close);
        }
    }
    try buf.appendSlice(self.allocator, "}");
    const result = try self.allocator.dupe(u8, buf.items);

    // double-check 후 put. race 로 다른 스레드가 이미 put 했으면 내 result 폐기.
    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();
    if (self.ns_inline_cache.get(target_mod_idx)) |raced| {
        self.allocator.free(result);
        return try self.allocator.dupe(u8, raced);
    }
    try mutable_self.ns_inline_cache.put(self.allocator, target_mod_idx, result);
    return try self.allocator.dupe(u8, result);
}

fn allocNamespaceGetterValue(self: *const Linker, exp: NsExportPair) std.mem.Allocator.Error!?[]const u8 {
    const init_mod_idx = exp.init_mod orelse return null;
    const init_mod = self.graph.getModule(@enumFromInt(init_mod_idx)) orelse return null;
    if (init_mod.wrap_kind != .esm) return null;

    const init_expr = try allocEsmInitExpr(self, init_mod);
    defer self.allocator.free(init_expr);
    const sep = if (self.minify_whitespace) "," else ", ";
    return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ init_expr, sep, exp.local });
}

/// `target_init` 은 호출자가 미리 1회 계산한 target 모듈의 init 식 (예: `init_X()` 또는
/// `__zntc_modules["..."].fn()`). dev_mode 의 lazy 런타임에서만 호출되며, 비-dev 호출 경로는
/// caller 에서 차단된다 (top-level `init_X()` preamble 이 init 을 이미 보장).
///
/// `source_init_cache` 는 호출자가 owned. 같은 `source_mod_idx` 가 같은
/// `registerNamespaceRewrites` 호출 안에서 반복되는 barrel re-export 케이스 대비.
fn allocNamespaceMemberRewriteValue(
    self: *const Linker,
    target_init: ?[]const u8,
    target_mod_idx: u32,
    exp: NsExportPair,
    source_init_cache: *std.AutoHashMap(u32, ?[]const u8),
) std.mem.Allocator.Error!?[]const u8 {
    const source_init: ?[]const u8 = if (exp.init_mod) |source_mod_idx| blk: {
        if (source_mod_idx == target_mod_idx) break :blk null;
        const gop = try source_init_cache.getOrPut(source_mod_idx);
        if (!gop.found_existing) {
            // alloc 실패 시 entry 의 value_ptr.* 가 undefined 로 남아 defer 가
            // 잘못 dereference. 미초기화 entry 제거 후 에러 전파.
            errdefer _ = source_init_cache.remove(source_mod_idx);
            gop.value_ptr.* = try allocEsmInitExprForModuleIndex(self, source_mod_idx);
        }
        break :blk gop.value_ptr.*;
    } else null;

    const sep = if (self.minify_whitespace) "," else ", ";
    if (target_init) |target_expr| {
        if (source_init) |source_expr| {
            return try std.fmt.allocPrint(self.allocator, "({s}{s}{s}{s}{s})", .{ target_expr, sep, source_expr, sep, exp.local });
        }
        return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ target_expr, sep, exp.local });
    }
    if (source_init) |source_expr| {
        return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ source_expr, sep, exp.local });
    }
    return null;
}

fn allocEsmInitExprForModuleIndex(self: *const Linker, mod_idx: u32) std.mem.Allocator.Error!?[]const u8 {
    const mod = self.graph.getModule(@enumFromInt(mod_idx)) orelse return null;
    if (mod.wrap_kind != .esm) return null;
    return try allocEsmInitExpr(self, mod);
}

pub fn allocEsmInitExpr(self: *const Linker, target_mod: *const Module) std.mem.Allocator.Error![]const u8 {
    const guard = target_mod.shouldGuard(self.entry_error_guard);
    // 일반 init 식 길이가 30~90B (`__zntc_modules["..."].fn()` + guard wrap).
    // 96B 로 1회 alloc 하면 grow realloc 없이 toOwnedSlice 시 trim 만 발생.
    var buf = try std.ArrayList(u8).initCapacity(self.allocator, 96);
    errdefer buf.deinit(self.allocator);
    var adapter = ArrayListWriter{ .buf = &buf, .allocator = self.allocator };
    try writeEsmInitExprBody(self, &adapter, target_mod, guard);
    if (guard) try buf.appendSlice(self.allocator, "})");
    return try buf.toOwnedSlice(self.allocator);
}

/// `appendEsmInitCall` (statement) / `allocEsmInitExpr` (expression) 의 공통 init 식 본문.
/// await prefix 와 close 토큰 (statement `;});\n`/`;\n` vs expression `})`/없음) 만
/// caller 가 결정한다. `guard` 는 양쪽 caller 가 close 토큰 결정 시에도 필요해 외부에서 1회 계산.
pub fn writeEsmInitExprBody(
    self: *const Linker,
    writer: anytype,
    target_mod: *const Module,
    guard: bool,
) !void {
    if (guard) try writer.write(if (self.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN);
    if (self.dev_mode) {
        try writer.write("__zntc_modules[\"");
        try writer.write(target_mod.dev_id);
        try writer.write("\"].fn()");
    } else {
        const init_name = try target_mod.allocInitName(self.allocator);
        defer self.allocator.free(init_name);
        try writer.write(init_name);
        try writer.write("()");
    }
}

/// anytype 슬롯 어댑터 — PreambleWriter 와 동일한 `.write([]const u8) !void` 인터페이스로
/// ArrayList 에 모은다. PreambleWriter 직접 사용 시 `toOwned` 가 dupe + deinit 라 alloc 1회
/// 추가 → toOwnedSlice 이전을 쓰기 위해 별도 어댑터.
const ArrayListWriter = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pub inline fn write(self: *ArrayListWriter, s: []const u8) std.mem.Allocator.Error!void {
        try self.buf.appendSlice(self.allocator, s);
    }
};

/// JS 예약어인 export 이름은 프로퍼티 키에 따옴표 필요.
fn needsPropertyQuoteForExport(name: []const u8) bool {
    if (name.len == 0) return true;
    const reserved = [_][]const u8{
        "default", "class",      "function", "var",    "let",    "const",
        "if",      "else",       "for",      "while",  "do",     "switch",
        "case",    "break",      "continue", "return", "throw",  "try",
        "catch",   "finally",    "new",      "delete", "typeof", "void",
        "in",      "instanceof", "this",     "with",   "yield",  "await",
        "import",  "export",     "extends",  "super",  "enum",
    };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    if (name[0] >= '0' and name[0] <= '9') return true;
    if (name[0] != '_' and name[0] != '$' and !(name[0] >= 'a' and name[0] <= 'z') and !(name[0] >= 'A' and name[0] <= 'Z')) return true;
    return false;
}

// ================================================================
// G1-step2: tryRewriteGetterObjToArrowExport 회귀 가드
// ================================================================

test "G1-step2: 순수 getter object ≥9 → arrow map 변환" {
    const a = std.testing.allocator;
    // 9 getter (= ARROW_EXPORT_MIN), 모두 단순 identifier value
    const obj = "{get a(){return x},get b(){return y},get c(){return z}," ++
        "get d(){return p},get e(){return q},get f(){return r}," ++
        "get g(){return s},get h(){return t},get i(){return u}}";
    const got = (try tryRewriteGetterObjToArrowExport(a, obj)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "{a:()=>x,b:()=>y,c:()=>z,d:()=>p,e:()=>q,f:()=>r,g:()=>s,h:()=>t,i:()=>u}",
        got,
    );
}

test "G1-step2: export < 9 → null (helper 고정비용 미회수)" {
    const a = std.testing.allocator;
    const obj = "{get a(){return x},get b(){return y}}";
    try std.testing.expect((try tryRewriteGetterObjToArrowExport(a, obj)) == null);
}

test "G1-step2: nested re-export (non-getter prop) 섞이면 null" {
    const a = std.testing.allocator;
    // 8 getter + 1 nested `ns:{...}` → 순수 getter object 아님 → null
    const obj = "{get a(){return x},get b(){return y},get c(){return z}," ++
        "get d(){return p},get e(){return q},get f(){return r}," ++
        "get g(){return s},get h(){return t},ns:{get k(){return w}}}";
    try std.testing.expect((try tryRewriteGetterObjToArrowExport(a, obj)) == null);
}

test "G1-step2: 복잡 VAL (call/string/depth) depth-track 보존" {
    const a = std.testing.allocator;
    // VAL 안에 (), {}, string literal 의 `}` `,` 가 있어도 정확히 분리
    const obj = "{get a(){return f(p,q)},get b(){return {k:1}}," ++
        "get c(){return \"a,b}c\"},get d(){return r},get e(){return s}," ++
        "get f(){return t},get g(){return u},get h(){return v}," ++
        "get \"q-x\"(){return w}}";
    const got = (try tryRewriteGetterObjToArrowExport(a, obj)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings(
        "{a:()=>f(p,q),b:()=>({k:1}),c:()=>\"a,b}c\",d:()=>r,e:()=>s," ++
            "f:()=>t,g:()=>u,h:()=>v,\"q-x\":()=>w}",
        got,
    );
}
