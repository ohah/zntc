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

// RFC PR-2 (#3399) kill-switch: env `ZNTC_NO_NS_REWRITE` presence → namespace
// member-rewrite 강제 비활성 (회귀 시 운영 비상 차단 + measure-first OFF
// 측정). force-ON 은 *제공하지 않는다* — 비-minify 강제 ON 은 의도적으로
// 깨진 출력(자기-shadow 무한재귀)을 만들 수 있어 footgun. 활성 여부는
// `Linker.nsMemberRewriteSafe()` (mangler invariant 기반) 가 단독 결정하고
// 이 env 는 그것을 덮어 끄기만 한다.
const ns_rewrite_disabled_env = @import("../../env_flag.zig").Once("ZNTC_NO_NS_REWRITE");

pub fn nsRewriteDisabled() bool {
    return ns_rewrite_disabled_env.enabled();
}

/// ESM namespace import를 위한 namespace 객체 preamble 생성.
/// namespace import/re-export에 대해 ns_member_rewrites + ns_inline_objects를 등록.
/// buildMetadataForAst 내 3곳에서 동일 패턴을 공유. 캐시는 linker 전역
/// (`self.ns_export_cache` / `self.ns_inline_cache`) — 같은 target 을 여러
/// importer 가 namespace import 할 때 collectExportsRecursive DFS 를 단 한 번만 수행.
///
/// `force_inline`: caller 가 isNamespaceUsedAsValue / exported_locals 등으로 결정한
/// 강제 inline 신호. shadow 충돌은 함수 안에서 자체 감지하여 ns_inline_list 를 활성화.
/// `force_target_init`: caller preamble 이 target namespace 모듈 init 을 보장하지 못하는
/// named-import-of-namespace-export 경로에서 member rewrite 값에 target init 을 붙인다.
///
/// (#4564) namespace 멤버 `ns.<exported>` 가 cross-chunk 로 노출될 때 소비자 본문/getter/inline 이
/// 참조해야 하는 **전역 공개명**을 해석한다. re-export 배럴(`source_mod`)은 멤버를 재-export만 하므로
/// 전역명은 배럴이 아니라 **정의 모듈(canonical)** 키로 등록·소비된다. 그래서:
///   1. `source_mod` 가 직접 정의·cross-chunk 면 그 키로 조회(direct namespace).
///   2. miss 면 `resolveExportChain` 으로 canonical(정의 모듈)을 해석해 **그 키**로 조회.
/// 게이트는 **각 키의 정의 모듈** 기준 `isCrossChunkConsumer` 다 — 배럴이 소비자와 같은 청크여도
/// 정의 모듈이 다른 청크로 split 되면 전역명이 필요하기 때문(code-review; import rename 경로
/// metadata.zig 와 canonical 기준으로 일치). synthetic_named_exports 는 canonical 이 컨테이너
/// export 를 가리키고 실제 멤버는 `synthetic_member` 라 `<global>.<member>` 로 접근(축약 금지).
/// 반환 null = cross-chunk 전역명 없음(caller 가 `exp.local` fallback). synthetic 표현식은
/// `owned_values` 로 소유권 이전(caller 가 metadata deinit 에서 해제).
///
/// ⚠️ named-import rename 경로 `metadata.zig` 의 `effective_target`(+`synth_member`)이 **같은
/// canonical→cross-chunk-global 매핑**을 한다(이미 resolved 된 `rb.canonical` 로 시작하는 점만 다름).
/// 게이트/전역명 키/synthetic 형식을 바꾸면 **양쪽 같이** 고쳐야 namespace-멤버와 named-import 가
/// 어긋나지 않는다(#4101/#4492/#4502 계열 드리프트). 통합 헬퍼화는 후속.
fn crossChunkNsMemberName(
    self: *const Linker,
    consumer_mod: u32,
    source_mod: u32,
    exported: []const u8,
    owned_values: *std.ArrayListUnmanaged([]const u8),
) std.mem.Allocator.Error!?[]const u8 {
    // 청크 컨텍스트 없음(단일 번들 / preserve_modules) → cross-chunk 전역명 자체가 없다. 아래
    // resolveExportChain(대형 배럴서 export 당 chain walk)를 통째로 skip (code-review: non-splitting perf).
    if (self.module_to_chunk == null) return null;
    // 1. source 가 직접 이 export 를 정의·cross-chunk 로 노출 (direct namespace target).
    if (self.isCrossChunkConsumer(consumer_mod, source_mod)) {
        if (self.getCrossChunkGlobalName(source_mod, exported)) |g| return g;
    }
    // 2. canonical(정의 모듈) 해석 후 그 키로 — 배럴 재-export / renamed re-export(`as`) 커버.
    // **Uncached**: 병렬 emit 스레드서 cold key 로 캐싱 resolveExportChain 을 부르면 chain_cache
    // 데이터 레이스(위 wrapper 락 없음). resolveExportChainUncached 로 우회.
    const canon = self.resolveExportChainUncached(@enumFromInt(source_mod), exported) orelse return null;
    const canon_mod = @intFromEnum(canon.module_index);
    if (!self.isCrossChunkConsumer(consumer_mod, canon_mod)) return null;
    const g = self.getCrossChunkGlobalName(canon_mod, canon.export_name) orelse return null;
    if (canon.synthetic_member) |member| {
        const expr = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ g, member });
        errdefer self.allocator.free(expr);
        try owned_values.append(self.allocator, expr);
        return expr;
    }
    return g;
}

pub fn registerNamespaceRewrites(
    self: *const Linker,
    ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
    ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
    owned_rewrite_values: *std.ArrayListUnmanaged([]const u8),
    /// 같은 importer 안에서 여러 namespace import 가 같은 target source 의 inline ns_var
    /// 를 공유하도록 caller 가 owned. `cjs_var_cache` 와 같은 패턴 (`metadata.zig`).
    ns_target_to_var: *std.AutoHashMapUnmanaged(u32, []const u8),
    /// PR #3742 (C7 F3 follow-up): nested bindings set 도 caller-owned cache.
    /// 같은 importer 안 N 개 ns import 가 동일한 set 재build 회피 (per-importer 1회).
    /// null 으로 시작, 첫 호출에서 lazy build. caller 가 `defer if (cache) |*c| c.deinit()`.
    /// per-thread — emit thread 마다 별도 buildMetadataForAst → 별도 cache (caller stack frame).
    nested_bindings_cache: *?std.StringHashMapUnmanaged(void),
    force_inline: bool,
    force_target_init: bool,
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
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.allocator);
        var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer visited.deinit(self.allocator);
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

    var seen_exports: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_exports.deinit(self.allocator);
    // PR #3741 (C7 perf): capacity hint — cached_exports.len 만큼 미리 알loc 해서 rehash 회피.
    try seen_exports.ensureTotalCapacity(self.allocator, @intCast(cached_exports.len));
    for (cached_exports) |exp| {
        try seen_exports.put(self.allocator, exp.exported, {});
    }

    // importer 의 nested binding 과 충돌하는 export 는 inline 시 self-shadow 무한
    // 재귀 위험 → 매핑 등록을 건너뛰고 has_shadow 로 추적.
    // (예: `const setSelectedLog = (i) => LogBoxData.setSelectedLog(i);` 가
    //  `const setSelectedLog = (i) => setSelectedLog(i);` 로 inline 되는 케이스)
    //
    // 또한 ns_target_mod 가 있는 export (re_export_namespace 등) 는 target_mod 별
    // hoisted ns_var 를 만들고 inner_map 매핑은 그 변수명으로 둔다 — emitStaticMember
    // 가 access site 마다 객체 literal 을 inline emit 하는 회귀 방지 (#1928).
    var inner_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var inner_map_transferred = false;
    errdefer if (!inner_map_transferred) inner_map.deinit(self.allocator);
    // PR #3741 (C7 perf): capacity hint — cached_exports.len entries 예상.
    try inner_map.ensureTotalCapacity(self.allocator, @intCast(cached_exports.len));
    var has_shadow = false;
    // target_init 은 target_mod_idx 에만 의존하므로 export 마다 재계산할 필요가 없다.
    // dev lazy runtime 에서는 access site 가 package entry 도 깨워야 하므로 target init 을
    // 포함한다. release 는 module preamble 이 target init 을 이미 보장하므로 source init 만
    // rewrite value 에 붙인다.
    const target_init: ?[]const u8 = if (self.dev_mode or force_target_init)
        try allocEsmInitExprForModuleIndex(self, target_mod_idx)
    else
        null;
    defer if (target_init) |expr| self.allocator.free(expr);
    // barrel re-export (`export { a, b, c } from './x'`) 에서 같은 source_mod_idx 가
    // export 마다 반복 → 매번 `allocEsmInitExprForModuleIndex` 가 동일한 init 식을 새로
    // alloc. 호출자가 owned 한 캐시로 1회 alloc + 재사용. null 결과 (source.wrap_kind
    // != .esm) 도 캐시해 이중 lookup 회피. 같은 패턴: `cjs_var_cache` (metadata.zig).
    var source_init_cache: std.AutoHashMapUnmanaged(u32, ?[]const u8) = .empty;
    defer {
        var it = source_init_cache.valueIterator();
        while (it.next()) |value_ptr| {
            if (value_ptr.*) |expr| self.allocator.free(expr);
        }
        source_init_cache.deinit(self.allocator);
    }
    // RFC PR-2 (#3399): mangle-safe 경로면 shadow-skip 을 끄고 멤버를 inner_map
    // 에 등록 → `emitStaticMember` 가 `X.member`→exp.local 직접 재작성 →
    // ns-object 불요 (effect −20.6%). 안전성 근거·스코핑은
    // `Linker.nsMemberRewriteSafe` docstring. `ZNTC_NO_NS_REWRITE` 는 회귀 시
    // 강제 비활성(kill-switch) — 안전 경로에서도 끌 수만 있고 켤 수는 없다.
    const ns_rewrite = !nsRewriteDisabled() and self.nsMemberRewriteSafe();

    // PR #3741 (C7) + #3742 (F3 follow-up): caller-owned nested bindings cache.
    // 같은 importer 의 N 개 ns import → cache 1회 build, 이후 fetch (per-importer 1회).
    // ns_rewrite=true 면 cache 빌드 자체 skip — `nested_bindings_cache.*` 가 null 유지.
    if (!ns_rewrite and nested_bindings_cache.* == null) {
        if (self.getModule(importer_mod_idx)) |importer_mod| {
            if (importer_mod.semantic) |sem| {
                var nb: std.StringHashMapUnmanaged(void) = .empty;
                errdefer nb.deinit(self.allocator);
                // F2: capacity hint — non-module-scope 의 entry 합 추정.
                var est: usize = 0;
                for (sem.scope_maps, 0..) |scope_map, scope_idx| {
                    if (scope_idx == 0) continue;
                    est += scope_map.count();
                }
                try nb.ensureTotalCapacity(self.allocator, @intCast(est));
                for (sem.scope_maps, 0..) |scope_map, scope_idx| {
                    if (scope_idx == 0) continue;
                    var it = scope_map.iterator();
                    while (it.next()) |entry| {
                        try nb.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
                nested_bindings_cache.* = nb;
            }
        }
    }

    // (#3982) 2+ `export *` 소스가 있는 barrel 만 ambiguity 검사(흔한 0~1 star 는 비용 0).
    const ambiguity_possible = self.starReExportCount(@enumFromInt(target_mod_idx)) >= 2;

    for (cached_exports) |exp| {
        const is_shadow = blk: {
            if (ns_rewrite) break :blk false;
            const nb = nested_bindings_cache.* orelse break :blk false;
            break :blk nb.contains(exp.exported);
        };
        if (is_shadow) {
            has_shadow = true;
            continue;
        }
        // (#3982) 같은 이름이 2+ distinct star 소스에서 도달하면 ESM spec 상 ambiguous —
        // namespace 멤버는 undefined. `void 0` 으로 매핑하면 emitStaticMember 가 access
        // 를 `void 0` 으로 재작성(materialize 안 된 inline ns 의 dangling 참조 방지).
        if (ambiguity_possible and self.isAmbiguousStarExport(@enumFromInt(target_mod_idx), exp.exported)) {
            try inner_map.put(self.allocator, exp.exported, "void 0");
            continue;
        }
        if (exp.ns_target_mod) |target| {
            // (#3975) target 이 CJS 면 정적 ns-object(buildInlineObjectStr=빈 {})로는
            // 동적 멤버를 못 담는다. 멤버를 `__toESM(require_cjs())` 표현식으로 재작성 →
            // `ns.inner` → `__toESM(require_cjs())`, 접근 시점 평가(CJS wrapper 정의 후)라
            // ordering 안전(var cjs_ns={} 빈객체 + shared-preamble ordering 버그 회피).
            // require_cjs 는 dev/production 양쪽에서 정의됨. production 의 inner 는
            // metadata.zig namespaceHasCjsStar 분기가 먼저 처리하므로 이 경로는 주로 dev.
            if (self.getModule(target)) |tm| {
                if (tm.wrap_kind == .cjs) {
                    const req = try tm.allocRequireName(self.allocator, &self.rename_table);
                    defer self.allocator.free(req);
                    const toesm: []const u8 = if (self.minify_whitespace) rt.NAMES.TOESM_MIN else "__toESM";
                    const expr = try std.fmt.allocPrint(self.allocator, "{s}({s}())", .{ toesm, req });
                    errdefer self.allocator.free(expr);
                    try owned_rewrite_values.append(self.allocator, expr);
                    try inner_map.put(self.allocator, exp.exported, expr);
                    continue;
                }
            }
            const ns_var = if (ns_target_to_var.get(target)) |cached|
                cached
            else blk: {
                if (self.useSharedNsInline(target)) {
                    const ns_var_name = try appendSharedNsInlineEntry(self, ns_inline_list, null, target, &seen_exports);
                    try ns_target_to_var.put(self.allocator, target, ns_var_name);
                    break :blk ns_var_name;
                }
                const fresh = try makeUniqueNsVarName(self, exp.exported, &seen_exports);
                try ns_target_to_var.put(self.allocator, target, fresh);
                // 비-shared 경로 — 리터럴은 importer 의 self-preamble(= importer 청크) 로 들어간다.
                const obj_str = try buildInlineObjectStr(self, importer_mod_idx, target, 0);
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
            try inner_map.put(self.allocator, exp.exported, ns_var);
            continue;
        }
        // #4101 ns collision: target inner const 가 다른 ns 의 동명 const 와 deconflict(`k`/`k$1`)
        // 되면 이 멤버 재작성(`ns.k`→local)이 잘못된 const 를 가리킨다. cross-chunk 전역명(emit 前
        // 글로벌 패스로 확정)을 써 provider·consumer 양쪽 일치. 배럴 재-export·renamed re-export·
        // synthetic 는 crossChunkNsMemberName 이 canonical 해석으로 커버. 없으면 exp.local (#4564).
        const member_name = (try crossChunkNsMemberName(self, importer_mod_idx, target_mod_idx, exp.exported, owned_rewrite_values)) orelse exp.local;
        // init 식이 필요한 경로(dev/force_target_init/ESM source)는 그 식에 member_name 을 embed.
        if (try allocNamespaceMemberRewriteValue(self, target_init, target_mod_idx, exp, member_name, &source_init_cache)) |rewrite_value| {
            var owned_by_list = false;
            errdefer if (!owned_by_list) self.allocator.free(rewrite_value);
            // ns_member_rewrites map 은 포인터만 빌리고, 실제 소유권은
            // LinkingMetadata.owned_rename_values 로 이전해 metadata deinit 에서 해제한다.
            try owned_rewrite_values.append(self.allocator, rewrite_value);
            owned_by_list = true;
            try inner_map.put(self.allocator, exp.exported, rewrite_value);
            continue;
        }
        try inner_map.put(self.allocator, exp.exported, member_name);
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
            // 비-shared 경로 — importer self-preamble(= importer 청크) 이 emitter.
            const obj_str = try buildInlineObjectStr(self, importer_mod_idx, target_mod_idx, 0);
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer {
        for (exports.items) |e| if (e.owned) self.allocator.free(e.local);
        exports.deinit(self.allocator);
        seen.deinit(self.allocator);
        visited.deinit(self.allocator);
    }
    try self.collectExportsRecursive(&exports, &seen, &visited, target, 0);
    var seen_exports: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_exports.deinit(self.allocator);
    for (exports.items) |e| try seen_exports.put(self.allocator, e.exported, {});
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
    seen_exports: *std.StringHashMapUnmanaged(void),
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
    seen_exports: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error![]const u8 {
    const mutable_self = @constCast(self);

    mutable_self.ns_cache_mutex.lock();
    if (self.ns_shared_inline_cache.get(target_mod_idx)) |cached| {
        mutable_self.ns_cache_mutex.unlock();
        return cached.var_name;
    }
    mutable_self.ns_cache_mutex.unlock();

    // shared 경로 — 리터럴은 **정의자 청크**(=target 이 속한 청크) preamble 로 들어간다.
    // 이 시점(computeCrossChunkLinks/metadata)엔 청크 컨텍스트가 없을 수도 있어 sentinel 키로
    // 캐시된다. splitting emit 은 appendSharedNamespacePreambleFiltered 가 청크-확정 이름으로
    // 재빌드하므로 여기 값은 단일 번들 / 증분 persist 용 스냅샷이다 (#4502).
    const object_literal = try buildInlineObjectStr(self, target_mod_idx, target_mod_idx, 0);
    errdefer self.allocator.free(object_literal);
    const base_name = try makeSharedNamespaceBaseName(self, target_mod_idx);
    defer self.allocator.free(base_name);

    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();

    if (self.ns_shared_inline_cache.get(target_mod_idx)) |raced| {
        self.allocator.free(object_literal);
        return raced.var_name;
    }

    try ensureNsBaseRank(mutable_self);
    const rank = mutable_self.ns_base_rank.get(target_mod_idx) orelse 0;
    const fresh = try makeUniqueSharedNsVarNameLocked(mutable_self, base_name, rank, seen_exports);
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
        // (#4101 / #4502) `entry.object_literal` 은 청크·rename 확정 *전*(computeCrossChunkLinks 의
        // ensureSharedNsVar)에 frozen 됐다 — getter 본문이 미-deconflict 원본 이름이다.
        // splitting emit(=`module_to_chunk` 세팅)에서는 이 리터럴이 **정의자 청크**(target 의 청크)
        // preamble 로 들어가고, 호출 시점은 그 청크의 `computeRenamesForModules` *이후* 다(emit
        // 루프가 그렇게 배치, chunks.zig 의 ns preamble insert 참조). 따라서 여기서 emitter=target
        // 으로 재빌드하면 getter 가 (같은 청크 선언 → 확정된 chunk-local 이름 / 다른 청크 선언 →
        // cross-chunk 전역 공개명) 을 정확히 고른다. 결과는 `(청크, target)` 키로 캐시되므로 청크당
        // 1회. 단일 번들/preserve_modules(청크 컨텍스트 없음)는 frozen 유지 → byte-identical.
        // OOM 시 frozen fallback (`rebuilt == null`).
        const rebuilt: ?[]const u8 = if (self.module_to_chunk != null)
            buildInlineObjectStr(self, target_mod_idx, target_mod_idx, 0) catch null
        else
            null;
        defer if (rebuilt) |r| self.allocator.free(r);
        const obj_literal = rebuilt orelse entry.object_literal;
        if (self.minify_whitespace) {
            if (try tryRewriteGetterObjToArrowExport(self.allocator, obj_literal)) |arrow_map| {
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
        try out.appendSlice(self.allocator, obj_literal);
        try out.appendSlice(self.allocator, ";\n");
        // 큰 namespace inline 의 size 영향 측정. `get NAME(){return VAL}` 패턴은
        // esbuild/rolldown 의 `NAME:()=>VAL` arrow `__export` 보다 per-export ~9 byte 큼
        // (~9 exports 부터 helper 패턴이 더 짧음). 어느 라이브러리에서 격차가 큰지
        // 식별용 — export count 는 `get ` prefix 개수로 근사.
        if (debug_log.enabled(.ns_inline_audit)) {
            const literal = obj_literal;
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

    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(allocator);

    for (md.ns_inline_objects.entries) |entry| {
        const target_mod_idx = entry.shared_target_mod_idx orelse continue;
        if (seen.contains(target_mod_idx)) continue;
        try seen.put(allocator, target_mod_idx, {});

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

/// (#3966) sanitized base 가 같은 모듈들의 결정적 rank 를 1회 계산해 캐싱.
/// renumber(#3564) 후 module_index 는 path-sorted 라 0..moduleCount 순회가
/// 결정적. rank>0 (충돌) 인 모듈만 map 에 저장 — 부재 시 rank 0.
/// 호출처(getOrCreateSharedNamespaceVar)가 `ns_cache_mutex` 를 보유한 상태에서
/// 부르므로 별도 락 불필요.
fn ensureNsBaseRank(self: *Linker) std.mem.Allocator.Error!void {
    if (self.ns_base_rank_built) return;
    self.ns_base_rank_built = true;

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var it = counts.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        counts.deinit(self.allocator);
    }

    const n: u32 = @intCast(self.graph.moduleCount());
    var idx: u32 = 0;
    while (idx < n) : (idx += 1) {
        const base = try makeSharedNamespaceBaseName(self, idx);
        defer self.allocator.free(base);
        const gop = try counts.getOrPut(self.allocator, base);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, base);
            gop.value_ptr.* = 0;
        }
        const rank = gop.value_ptr.*;
        gop.value_ptr.* = rank + 1;
        if (rank > 0) {
            try self.ns_base_rank.put(self.allocator, idx, rank);
        }
    }
}

/// (#4545 hole 3) `import * as ns` 의 합성 shared-ns var 이름을 결정하는 입력
/// (sanitized base name + 전-모듈 동명-base 충돌 rank)을 해시한다. 이 이름이 collision
/// 구성 변화(동명 base 모듈 추가/삭제)로 `t_ns`→`t_ns_2` 처럼 바뀌면 이 해시가 바뀌고,
/// 그 값이 target(namespace 주인) 모듈의 `emitFingerprint` 에 접혀 deep-fold 로 `ns.member`
/// 참조 소비자를 invalidation 한다(증분 emit stale 방지 — hole 3).
///
/// base+rank 는 단일번들·splitting 공통으로 결정적이다 — 두 경로 모두 실제 이름을
/// `makeUniqueSharedNsVarNameLocked` 의 `base`+`rank` 로 만든다. module-set 변화가 곧 rank
/// 변화이므로 "동명-base 모듈 추가/삭제" 시나리오를 완전 포착한다. 잔여 bump 원인
/// (`ns_shared_var_names`/`seen_exports` 재충돌)은 (a) module-set 변화 시 rank 로,
/// (b) target 자기 export 와의 충돌 시 emitFingerprint 의 export_bindings 해시로 이미 흡수된다.
/// ⚠️ 단조 안전 — fp 입력 추가는 항상 "더 많이 감지"(deterministic → 새 false-hit 불가).
///
/// fp 는 병렬 emit 진입 *전* 단일 스레드(emitter.zig 의 emitDeepFingerprint 루프)에서만
/// 계산되지만, `ensureNsBaseRank` 의 "ns_cache_mutex 보유" 불변식을 지키려 락을 잡는다
/// (무경쟁이라 저비용; emitFingerprint 호출 경로 중 이 락 보유자가 없어 deadlock 없음).
/// `use_shared_ns_preamble` 가 이 시점엔 false 라 `ns_shared_inline_cache` 는 단일번들에서
/// 아직 비어 저장된 이름 조회는 불가 — 그래서 base+rank 를 재현한다.
pub fn sharedNsVarNameHash(self: *const Linker, target_mod_idx: u32) u64 {
    const base = makeSharedNamespaceBaseName(self, target_mod_idx) catch return 0;
    defer self.allocator.free(base);
    const h = std.hash.Wyhash.hash(0x4545_3, base);
    const mutable_self = @constCast(self);
    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();
    ensureNsBaseRank(mutable_self) catch return h; // OOM: base 만 반영(비-회귀).
    const rank = self.ns_base_rank.get(target_mod_idx) orelse 0;
    return h *% 31 +% @as(u64, rank);
}

/// rank 0 → `{base}_ns`, rank N>0 → `{base}_ns_{N+1}` (예: `core_ns`, `core_ns_2`).
/// rank 가 target 의 module_index 로 결정되므로 병렬 materialize 순서와 무관 (#3966).
/// 잔여 충돌(target 자체 export 와 동명 등 희소 케이스)은 결정적으로 증가.
fn makeUniqueSharedNsVarNameLocked(
    self: *Linker,
    base: []const u8,
    rank: u32,
    seen_exports: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error![]const u8 {
    var candidate = if (rank == 0)
        try std.fmt.allocPrint(self.allocator, "{s}_ns", .{base})
    else
        try std.fmt.allocPrint(self.allocator, "{s}_ns_{d}", .{ base, rank + 1 });
    if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;

    var i: usize = if (rank == 0) 2 else rank + 2;
    while (true) : (i += 1) {
        self.allocator.free(candidate);
        candidate = try std.fmt.allocPrint(self.allocator, "{s}_ns_{d}", .{ base, i });
        if (!seen_exports.contains(candidate) and !self.ns_shared_var_names.contains(candidate)) return candidate;
    }
}

/// namespace preamble 변수명을 export 이름과 충돌하지 않도록 생성.
/// "z" → "z_ns", 충돌 시 "z_ns2", "z_ns3", ...
fn makeUniqueNsVarName(self: *const Linker, base: []const u8, exports: *const std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error![]const u8 {
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

/// (#4502) `ns_inline_cache` 키 = `(emitter 청크 << 32) | target`.
/// 같은 target 이라도 리터럴을 **담는 청크(emitter)** 가 다르면 getter 본문 이름이 달라진다
/// (선언이 그 청크 안 → chunk-local rename / 밖 → cross-chunk 전역 공개명). target 단독 키면
/// 먼저 만든 청크의 문자열이 다른 청크로 새어 나간다. 청크 컨텍스트 부재(단일 번들 /
/// preserve_modules / emit 前)면 `.none`(=maxInt(u32)) 이 sentinel 슬롯이 된다.
fn nsInlineCacheKey(self: *const Linker, emitter_mod_idx: u32, target_mod_idx: u32) u64 {
    const chunk_bits: u64 = @intFromEnum(self.chunkOfModule(emitter_mod_idx));
    return (chunk_bits << 32) | @as(u64, target_mod_idx);
}

/// 모듈의 모든 export를 인라인 객체 문자열로 생성 (재귀적).
/// `export * as ns` export는 소스 모듈의 인라인 객체로 중첩.
/// 결과는 `self.ns_inline_cache` 에 `(emitter 청크, target)` 별로 캐싱 — linker 전역 공유.
///
/// `emitter_mod_idx`: 이 리터럴이 **어느 청크의 텍스트로 들어가는가**를 대표하는 모듈.
/// - shared 경로(정의자 청크 preamble) → target 자신
/// - 비-shared 경로(importer self-preamble) → importer 모듈
/// getter 본문 이름 해석이 이 청크 기준으로 갈린다 (#4502).
pub fn buildInlineObjectStr(
    self: *const Linker,
    emitter_mod_idx: u32,
    target_mod_idx: u32,
    depth: u32,
) std.mem.Allocator.Error![]const u8 {
    if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
    const target_any = self.getModule(target_mod_idx) orelse
        return try self.allocator.dupe(u8, "{}");

    const mutable_self = @constCast(self);
    const cache_key = nsInlineCacheKey(self, emitter_mod_idx, target_mod_idx);

    // 캐시 히트: 복사본 반환 (호출자가 소유권을 가짐)
    mutable_self.ns_cache_mutex.lock();
    const cache_hit = self.ns_inline_cache.get(cache_key);
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
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);
    var visited: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer visited.deinit(self.allocator);
    try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

    // export * as ns 패턴 수집 (별도 처리 — 재귀 인라인 필요)
    const target = target_any;
    var ns_re_exports: std.StringHashMapUnmanaged(u32) = .empty; // exported_name → source_mod
    defer ns_re_exports.deinit(self.allocator);
    for (target.export_bindings) |eb| {
        if (eb.kind == .re_export_namespace) {
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < target.import_records.len) {
                    const src = target.import_records[rec_idx].resolved;
                    if (!src.isNone()) {
                        try ns_re_exports.put(self.allocator, eb.exported_name, @intFromEnum(src));
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
    // (#4564) crossChunkNsMemberName 이 synthetic member 접근식(`<global>.<member>`)을 owned 로 낼
    // 수 있다. getter 본문은 buf 로 복사되므로 이 함수 종료 시 일괄 해제(borrow-then-copy).
    var owned_member_exprs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (owned_member_exprs.items) |e| self.allocator.free(e);
        owned_member_exprs.deinit(self.allocator);
    }
    // minify_whitespace 모드 토큰 — getter 패턴의 ` ` 와 `; ` 를 제거.
    // `get foo() { return bar; }` (30c) → `get foo(){return bar}` (24c).
    // 1699 getter 가 있는 effect 번들에서 ~10KB 절감.
    const min_ws = self.minify_whitespace;
    const list_sep: []const u8 = if (min_ws) "," else ", ";
    const colon_sep: []const u8 = if (min_ws) ":" else ": ";
    const get_open: []const u8 = if (min_ws) "(){return " else "() { return ";
    const get_close: []const u8 = if (min_ws) "}" else "; }";
    // (#3982) 2+ `export *` 소스 barrel 만 ambiguity 검사.
    const ambiguity_possible = self.starReExportCount(@enumFromInt(target_mod_idx)) >= 2;
    try buf.appendSlice(self.allocator, "{");
    var first = true;
    for (exports.items) |exp| {
        // (#3982) 같은 이름이 2+ distinct star 소스에서 도달하면 ESM spec 상 ambiguous —
        // namespace 객체에서 제외 → `ns.x`===undefined, `"x" in ns`===false (Node 동형).
        if (ambiguity_possible and self.isAmbiguousStarExport(@enumFromInt(target_mod_idx), exp.exported)) continue;
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
            // (#3975) `export * as inner from <CJS>`: CJS 멤버는 정적 열거 불가 →
            // 빈 `{}` 대신 `__toESM(require())` 로 런타임 namespace 를 만든다. 이 literal 은
            // namespaceHasCjsStar 경로(per-module preamble, CJS region 후)에서만 emit 되므로
            // require_x ordering 안전.
            if (self.getModule(src_mod)) |src_m| {
                if (src_m.wrap_kind == .cjs) {
                    const req = try src_m.allocRequireName(self.allocator, &self.rename_table);
                    defer self.allocator.free(req);
                    const toesm: []const u8 = if (self.minify_whitespace) rt.NAMES.TOESM_MIN else "__toESM";
                    try buf.appendSlice(self.allocator, toesm);
                    try buf.appendSlice(self.allocator, "(");
                    try buf.appendSlice(self.allocator, req);
                    try buf.appendSlice(self.allocator, "())");
                    continue;
                }
            }
            // 중첩 객체도 같은 emitter 청크의 텍스트 — emitter 를 그대로 물려준다.
            const nested = try buildInlineObjectStr(self, emitter_mod_idx, src_mod, depth + 1);
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
            // getter 본문 이름은 **이 리터럴을 담는 청크(emitter)** 기준으로 해석한다.
            //  - 선언이 다른 청크(#4101): 그 청크가 import 해 오는 cross-chunk 전역 공개명(provider
            //    public == consumer import 명이라 양쪽 일치). 배럴 재-export·renamed re-export·synthetic
            //    은 crossChunkNsMemberName 이 canonical 해석으로 커버 (#4564).
            //  - 선언이 같은 청크(#4502): 그 청크의 **확정된 chunk-local 이름**(=exp.local). 전역 공개명을
            //    쓰면 이 청크엔 그 이름의 선언이 없어 자유 변수 → ReferenceError. exp.local 이 확정 이름
            //    이려면 이 호출이 **per-chunk rename 이후**여야 한다(공유 ns preamble 을 emit 루프
            //    computeRenamesForModules 뒤로 옮긴 이유).
            // source 는 **namespace 소스(target_mod_idx = 배럴)** — decl_mod_idx(=exp.init_mod, 정의
            // 모듈)로 뿌리내리면 renamed re-export(`max as maximum`)에서 canonical 이 outer 명(`maximum`)
            // 을 못 따라간다(code-review). main 평탄화 경로와 동일하게 target 에서 chain 해석.
            const gmember = (try crossChunkNsMemberName(self, emitter_mod_idx, target_mod_idx, exp.exported, &owned_member_exprs)) orelse exp.local;
            if (try allocNamespaceGetterValue(self, exp, gmember)) |value| {
                defer self.allocator.free(value);
                try buf.appendSlice(self.allocator, value);
            } else {
                try buf.appendSlice(self.allocator, gmember);
            }
            try buf.appendSlice(self.allocator, get_close);
        }
    }
    try buf.appendSlice(self.allocator, "}");
    const result = try self.allocator.dupe(u8, buf.items);

    // double-check 후 put. race 로 다른 스레드가 이미 put 했으면 내 result 폐기.
    mutable_self.ns_cache_mutex.lock();
    defer mutable_self.ns_cache_mutex.unlock();
    if (self.ns_inline_cache.get(cache_key)) |raced| {
        self.allocator.free(result);
        return try self.allocator.dupe(u8, raced);
    }
    // put 실패 시에만 result 해제 (성공하면 맵이 소유 — errdefer 로 걸면 뒤의 dupe OOM 에서
    // 맵이 소유한 메모리를 또 해제해 double-free).
    mutable_self.ns_inline_cache.put(self.allocator, cache_key, result) catch |e| {
        self.allocator.free(result);
        return e;
    };
    return try self.allocator.dupe(u8, result);
}

fn allocNamespaceGetterValue(self: *const Linker, exp: NsExportPair, member_name: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const init_mod_idx = exp.init_mod orelse return null;
    const init_mod = self.graph.getModule(@enumFromInt(init_mod_idx)) orelse return null;
    if (init_mod.wrap_kind != .esm) return null;

    const init_expr = try allocEsmInitExpr(self, init_mod);
    defer self.allocator.free(init_expr);
    const sep = if (self.minify_whitespace) "," else ", ";
    // (#4564) member_name = caller 가 crossChunkNsMemberName 으로 해석한 cross-chunk 전역명(또는 exp.local).
    return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ init_expr, sep, member_name });
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
    // (#4564) 참조할 멤버명 — caller 가 crossChunkNsMemberName 으로 해석한 cross-chunk 전역명
    // (또는 exp.local). init 식 뒤 comma-expr 의 값 자리에 embed 된다.
    member_name: []const u8,
    source_init_cache: *std.AutoHashMapUnmanaged(u32, ?[]const u8),
) std.mem.Allocator.Error!?[]const u8 {
    const source_init: ?[]const u8 = if (exp.init_mod) |source_mod_idx| blk: {
        if (source_mod_idx == target_mod_idx) break :blk null;
        const gop = try source_init_cache.getOrPut(self.allocator, source_mod_idx);
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
            return try std.fmt.allocPrint(self.allocator, "({s}{s}{s}{s}{s})", .{ target_expr, sep, source_expr, sep, member_name });
        }
        return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ target_expr, sep, member_name });
    }
    if (source_init) |source_expr| {
        return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ source_expr, sep, member_name });
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
        const init_name = try target_mod.allocInitName(self.allocator, &self.rename_table);
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

// ================================================================
// #3966: shared namespace var 이름의 rank 기반 결정성 회귀 가드.
// rank 는 target 의 module_index(path-sorted) 로 결정되므로 병렬 emit
// materialize 순서와 무관하게 같은 base 의 충돌이 항상 같은 suffix 로 풀린다.
// ================================================================

fn testEmptyLinker(a: std.mem.Allocator, cache: *@import("../resolve_cache.zig").ResolveCache, graph: *@import("../graph.zig").ModuleGraph) Linker {
    cache.* = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    graph.* = @import("../graph.zig").ModuleGraph.init(a, cache);
    return Linker.init(a, graph, .esm);
}

test "#3966: rank → 결정적 ns var 이름 (rank 0 base_ns, rank N base_ns_{N+1})" {
    const a = std.testing.allocator;
    var cache: @import("../resolve_cache.zig").ResolveCache = undefined;
    var graph: @import("../graph.zig").ModuleGraph = undefined;
    var linker = testEmptyLinker(a, &cache, &graph);
    defer linker.deinit();
    defer graph.deinit();
    defer cache.deinit();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);

    // 같은 base("core") 의 rank 0/1/2 → core_ns / core_ns_2 / core_ns_3.
    // 발급 순서를 일부러 rank 역순(2→0→1)으로 호출해도 rank 만으로 이름이
    // 결정됨을 검증 (materialize 순서 무관성 = #3966 핵심).
    const n2 = try makeUniqueSharedNsVarNameLocked(&linker, "core", 2, &seen);
    defer a.free(n2);
    try std.testing.expectEqualStrings("core_ns_3", n2);
    try linker.ns_shared_var_names.put(a, n2, {});

    const n0 = try makeUniqueSharedNsVarNameLocked(&linker, "core", 0, &seen);
    defer a.free(n0);
    try std.testing.expectEqualStrings("core_ns", n0);
    try linker.ns_shared_var_names.put(a, n0, {});

    const n1 = try makeUniqueSharedNsVarNameLocked(&linker, "core", 1, &seen);
    defer a.free(n1);
    try std.testing.expectEqualStrings("core_ns_2", n1);
}

test "#3966: target 자체 export 와 동명 충돌 시 결정적 증가" {
    const a = std.testing.allocator;
    var cache: @import("../resolve_cache.zig").ResolveCache = undefined;
    var graph: @import("../graph.zig").ModuleGraph = undefined;
    var linker = testEmptyLinker(a, &cache, &graph);
    defer linker.deinit();
    defer graph.deinit();
    defer cache.deinit();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    // 모듈이 `x_ns` 라는 이름을 직접 export → rank 0 후보(x_ns) 충돌 → x_ns_2 로 증가.
    try seen.put(a, "x_ns", {});

    const got = try makeUniqueSharedNsVarNameLocked(&linker, "x", 0, &seen);
    defer a.free(got);
    try std.testing.expectEqualStrings("x_ns_2", got);
}
