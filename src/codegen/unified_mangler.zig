//! Unified Mangler — Issue #1760 Phase 1 스켈레톤.
//!
//! `mangleAll()` 한 번의 호출로 cross-module top-level + per-module nested
//! mangling 을 순차 수행한다. 두 phase 가 같은 base54 counter + reserved set
//! 을 공유해 shadow 를 원천 차단하고, `Symbol.canonical_name` 을 경유하지
//! 않는다 (결과는 `(module_index, symbol_id)` 키 HashMap).
//!
//! Phase 1 범위:
//!   - 타입 정의 + 동작하는 스켈레톤
//!   - 기존 `linker.computeMangling` / `buildMetadataForAst` 경로는 그대로
//!   - 이 모듈은 아직 호출되지 않음 — 단위 테스트와 후속 property 비교용
//!
//! 후속 단계 (#1760 마이그레이션 전략):
//!   2. 신/구 결과 property 비교 (번들 크기/이름 길이 총합/reserved/shadow)
//!   3. Bundler 의 호출 지점 교체
//!   4. 구 API / Symbol.canonical_name 제거

const std = @import("std");
const builtin = @import("builtin");
const mangler = @import("mangler.zig");
const debug_log = @import("../debug_log.zig");
const Scope = @import("../semantic/scope.zig").Scope;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Reference = @import("../semantic/symbol.zig").Reference;

pub const ModuleSymKey = struct {
    module_index: u32,
    symbol_id: u32,
};

/// 이 모듈이 import 한 cross-module symbol 의 source 위치. Phase A → Phase B
/// 사이에 각 source 의 mangled name 을 이 모듈의 per-mod reserved 에 등록
/// (selective broadcast) — nested mangle 이 cross-module Phase A 이름과 충돌
/// 회피. helper module / external 등 source 가 candidate 가 아닌 경우는 renames
/// 에 없으므로 자동 skip.
pub const ImportRef = struct {
    source_module_index: u32,
    source_symbol_id: u32,
};

/// Phase B 가 per-module 로 호출하는 mangler 입력. `mangler.MangleInput`
/// 과 동일한 semantic payload 에 더해, module scope 안의 symbol set 을 함께
/// 넘긴다 (Phase A 에서 이미 처리된 top-level 심볼을 skip 하기 위함).
pub const ModuleMangleInput = struct {
    scopes: []const Scope,
    symbols: []const Symbol,
    scope_maps: []const std.StringHashMap(usize),
    references: []const Reference,
    source: []const u8,
    /// scope_maps[0] 의 모든 symbol_id 를 담은 BitSet. `mangle` 이 skip_symbols
    /// 로 그대로 사용한다.
    module_scope_symbols: std.DynamicBitSet,
    /// 이 모듈이 import 한 cross-module symbol 의 source 위치.
    cross_module_imports: []const ImportRef = &.{},
    /// wrapper (CJS `__commonJS` / ESM `__esm`) 로 감싸져 *function scope* 격리된
    /// 모듈인지. true 면 internal binding 이 다른 모듈과 이름 겹쳐도 안전 (per-module
    /// pool 후보). false (bare scope-hoist) 는 top-level 이 한 scope 라 globally
    /// unique 필수. J-step3a (RFC #3288) 측정용.
    wrapper_isolated: bool = false,
};

/// Phase A 의 mangling 후보. 호출부가 빈도/필터링을 수행해 넘긴다
/// (범주: exported/imported/1-char/default/arguments/import binding 제외).
pub const TopLevelCandidate = struct {
    module_index: u32,
    symbol_id: u32,
    name: []const u8,
    ref_count: u32,
};

/// bundle-wide frequency 정렬 비교자. ref_count 내림차순, 동률은 name →
/// module_index → symbol_id (병렬 파싱 비결정 회피 — name 은 computeRenames
/// 이후 bundle-wide 유일하므로 결정적). Phase A 정렬과 buildGlobalFrequencyRank
/// 가 공유 (동일 우선순위 보장).
fn candidateLessThan(_: void, a: TopLevelCandidate, b: TopLevelCandidate) bool {
    if (a.ref_count != b.ref_count) return a.ref_count > b.ref_count;
    const name_order = std.mem.order(u8, a.name, b.name);
    if (name_order != .eq) return name_order == .lt;
    if (a.module_index != b.module_index) return a.module_index < b.module_index;
    return a.symbol_id < b.symbol_id;
}

/// RFC #3288 M2: bundle-wide frequency rank 맵 (key=ModuleSymKey, value=rank;
/// rank 0 = 최다 참조 = 최우선 1-char 후보). Phase A 의 *전역 frequency-sort*
/// (load-bearing — c2 가 이를 상실해 +61KB 회귀) 를 Phase B slot 발급
/// 우선순위로 보존하기 위한 자료구조. PR-1 inert (미연결); PR-2+ 가 소비.
/// caller 가 deinit 소유.
pub fn buildGlobalFrequencyRank(
    allocator: std.mem.Allocator,
    candidates: []const TopLevelCandidate,
) !std.AutoHashMap(ModuleSymKey, u32) {
    const sorted = try allocator.alloc(TopLevelCandidate, candidates.len);
    defer allocator.free(sorted);
    @memcpy(sorted, candidates);
    std.mem.sortUnstable(TopLevelCandidate, sorted, {}, candidateLessThan);

    var rank = std.AutoHashMap(ModuleSymKey, u32).init(allocator);
    errdefer rank.deinit();
    try rank.ensureUnusedCapacity(@intCast(sorted.len));
    for (sorted, 0..) |c, i| {
        // 같은 (module,symbol) 중복 candidate 는 첫(최우선) rank 유지.
        const gop = rank.getOrPutAssumeCapacity(.{ .module_index = c.module_index, .symbol_id = c.symbol_id });
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    return rank;
}

pub const UnifiedMangleInput = struct {
    modules: []const ModuleMangleInput,
    top_level_candidates: []const TopLevelCandidate,
    /// 런타임 헬퍼 이름 등 외부 예약어. Phase A 초기 reserved set 에 포함.
    global_reserved: []const []const u8 = &.{},
    /// RFC #3288 M2: true 면 Phase A candidate 를 즉시 base54 발급하지 않고
    /// Phase B slot pool 에 bundle-wide frequency 우선순위로 합류 (frequency
    /// 보존 + slot 공유). PR-1 inert (default false → 기존 Phase A 경로 100%
    /// 보존, byte-identical); PR-3 가 소비. c2(+61KB) 회귀를 frequency 보존
    /// 으로 정면 회피하는 경로의 게이트.
    enable_shared_slot_pool: bool = false,
};

pub const UnifiedMangleResult = struct {
    renames: std.AutoHashMap(ModuleSymKey, []const u8),
    allocator: std.mem.Allocator,
    phase_a: mangler.ManglerStats = .{},
    phase_b_modules: []mangler.ManglerStats = &.{},

    pub fn deinit(self: *UnifiedMangleResult) void {
        var it = self.renames.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.renames.deinit();
        self.allocator.free(self.phase_b_modules);
    }
};

/// 단일 호출 mangler. Phase A (빈도순 base54) + Phase B (per-module liveness)
/// 를 counter/reserved 공유 상태로 순차 실행.
pub fn mangleAll(
    allocator: std.mem.Allocator,
    input: UnifiedMangleInput,
) !UnifiedMangleResult {
    var renames: std.AutoHashMap(ModuleSymKey, []const u8) = .init(allocator);
    errdefer {
        var vit = renames.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        renames.deinit();
    }

    var reserved: std.StringHashMap(void) = .init(allocator);
    defer reserved.deinit();
    for (input.global_reserved) |r| try reserved.put(r, {});

    // ================================================================
    // Phase A — cross-module frequency
    // ================================================================
    const sorted = try allocator.alloc(TopLevelCandidate, input.top_level_candidates.len);
    defer allocator.free(sorted);
    @memcpy(sorted, input.top_level_candidates);
    // Tie-breaker 는 name 우선 — `module_index`/`symbol_id` 는 병렬 파싱으로
    // run 마다 다를 수 있어 non-deterministic 결과를 유발. 이름은
    // `computeRenames` 이후 bundle-wide 로 유일하므로 결정적 정렬 보장.
    std.mem.sortUnstable(TopLevelCandidate, sorted, {}, candidateLessThan);

    // Phase B 가 outer Phase A binding 과 shadow 충돌 (#1757) 을 피하려면 Phase A 가
    // mangle 한 이름을 nested mangle 시 reserve 해야 한다.
    //
    // **자기 모듈 Phase A**: `per_mod_reserved[cand.module_index]` 에 항상 등록.
    //
    // **다른 모듈 Phase A (cross-module)**: 순수 ESM bundle 은 wrapper IIFE 없이 모든 모듈
    // top-level 이 한 scope — 다른 모듈의 Phase A 이름도 visible 해 nested 가 shadow 가능
    // (`let n=n(p)` self-init TDZ). Phase B 진입 *전* 에 selective 로 broadcast — 각 모듈
    // 의 `cross_module_imports` 에 해당하는 source 의 mangled name 만 per-mod reserved 에
    // 추가 (전역 broadcast 가 아니라 실제 import 한 source 만 — size 회귀 회피).
    //
    // 보강 메커니즘 (`mangler.reserveNameFor` 가 import binding 의 `canonical_name` 으로
    // 자동 reserve) 는 `Symbol.canonical_name` 이 `mangleAll` 반환 *후* 에 linker 가
    // set 하므로 Phase B 진입 시점에는 빈 상태 — 여기서 명시적 selective broadcast 가 필요.
    //
    // (`renames` 만으로 derive 못 함 — Phase A 의 no-op rename, 즉 원본 이름과 mangled 이름이
    // 같은 경우도 reserved 에 등록해야 하지만 `renames` 에는 안 들어가기 때문.)
    //
    // init pass 와 seed pass 를 분리 — `StringHashMap.init` 자체는 fail 하지 않으므로
    // 두 번째 seed loop 의 `put` 이 OOM 해도 모든 entries 가 이미 init 되어 defer 의
    // `deinit` 이 안전하게 실행된다 (uninit deinit UB 없음).
    var per_mod_reserved = try allocator.alloc(std.StringHashMap(void), input.modules.len);
    for (per_mod_reserved) |*s| s.* = std.StringHashMap(void).init(allocator);
    defer {
        for (per_mod_reserved) |*s| s.deinit();
        allocator.free(per_mod_reserved);
    }
    // K2-perf (#46): global_reserved (runtime helper 등) 는 모든 모듈에 동일하므로 N×G
    // 알로케이션 (모듈마다 G entries put) 대신 한 번만 build 후 mangler 의 새
    // `external_reserved_global` 인자로 borrow 로 share. lookup 시 internal/per_mod 와
    // 함께 검사된다 (`nextNonReservedBase54NameTwo`). per_mod_reserved 는 이제 *Phase A
    // mangled this-module names + cross-module imports* 만 보유 — 일반적으로 작음.
    var global_reserved_set: std.StringHashMap(void) = .init(allocator);
    defer global_reserved_set.deinit();
    try global_reserved_set.ensureUnusedCapacity(@intCast(input.global_reserved.len));
    for (input.global_reserved) |r| global_reserved_set.putAssumeCapacity(r, {});

    // J-step2a (RFC #3288): cross-module ref 인 candidate 분류 — 진단 전용.
    // `cross_module_imports` source 집합. 여기 속하면 다른 모듈이 직접 참조 →
    // globally unique 필수. 속하지 않으면 module-internal (per-module pool 후보).
    // 본 step 은 *측정만* — mangle 로직 무변경 (회귀 0). per-module counter 실제
    // 적용은 후속 step (bare scope-hoist vs wrapper 격리 분류 정확성 선결 필요).
    // mangle_audit 비활성 시 set build + per-candidate lookup 전부 skip
    // (production hot path 낭비 회피).
    const audit_enabled = debug_log.enabled(.mangle_audit);
    var cross_module_ref_set = std.AutoHashMap(ModuleSymKey, void).init(allocator);
    defer cross_module_ref_set.deinit();
    if (audit_enabled) {
        for (input.modules) |m| {
            for (m.cross_module_imports) |ref| {
                try cross_module_ref_set.put(.{
                    .module_index = ref.source_module_index,
                    .symbol_id = ref.source_symbol_id,
                }, {});
            }
        }
    }

    var name_counter: u32 = 0;
    var name_buf: [8]u8 = undefined;
    var phase_a_slot_name_length_sum: usize = 0;
    var phase_a_renamed: usize = 0;
    var phase_a_skips_1char: usize = 0;
    var phase_a_cross_module: usize = 0;
    var phase_a_internal: usize = 0;
    // J-step3a: internal candidate 중 *wrapper 격리 모듈* 소속 (per-module pool
    // 진짜 안전) vs *bare scope-hoist* (한 scope, globally unique 필수) 분리 측정.
    var phase_a_internal_wrapped: usize = 0;

    for (sorted) |cand| {
        if (audit_enabled) {
            if (cross_module_ref_set.contains(.{ .module_index = cand.module_index, .symbol_id = cand.symbol_id })) {
                phase_a_cross_module += 1;
            } else {
                phase_a_internal += 1;
                if (cand.module_index < input.modules.len and input.modules[cand.module_index].wrapper_isolated)
                    phase_a_internal_wrapped += 1;
            }
        }
        const new_name = mangler.nextNonReservedBase54Name(&name_counter, &name_buf, &reserved, &phase_a_skips_1char);
        phase_a_slot_name_length_sum += new_name.len;

        // 일반적으로 production caller (linker.collectUnifiedInput) 는 candidate 의
        // module_index 가 input.modules.len 미만임을 보장한다. 단위 테스트는 candidate 만
        // 두고 modules 를 비울 수 있어 (Phase A 만 검증), 그 경우 per_mod_reserved 갱신은
        // 의미 없으므로 skip — 그 module 에 Phase B 호출 자체가 없어 shadow 도 발생 불가.
        const has_mod_slot = cand.module_index < per_mod_reserved.len;

        if (!std.mem.eql(u8, cand.name, new_name)) {
            const duped = try allocator.dupe(u8, new_name);
            errdefer allocator.free(duped);
            try renames.put(.{ .module_index = cand.module_index, .symbol_id = cand.symbol_id }, duped);
            try reserved.put(duped, {});
            if (has_mod_slot) try per_mod_reserved[cand.module_index].put(duped, {});
            phase_a_renamed += 1;
        } else {
            // 원본과 동일해도 다음 Phase A 후보가 같은 이름을 집지 못하도록 reserved.
            try reserved.put(cand.name, {});
            if (has_mod_slot) try per_mod_reserved[cand.module_index].put(cand.name, {});
        }
    }

    // Phase A 완료 후, 각 모듈의 cross-module import 의 source mangled name 을
    // *그 모듈* 의 per-mod reserved 에 추가. helper module / external 등 candidate
    // 가 아닌 source 는 `renames.get` 이 null 이라 자동 skip.
    for (input.modules, 0..) |m, mi| {
        for (m.cross_module_imports) |ref| {
            const key: ModuleSymKey = .{ .module_index = ref.source_module_index, .symbol_id = ref.source_symbol_id };
            if (renames.get(key)) |mangled| {
                try per_mod_reserved[mi].put(mangled, {});
            }
        }
    }

    const phase_a: mangler.ManglerStats = .{
        .slot_count = sorted.len,
        .slot_name_length_sum = phase_a_slot_name_length_sum,
        .name_counter_final = name_counter,
        .reserved_size = reserved.count(),
        .renamed_symbol_count = phase_a_renamed,
        .reserved_skips_1char = phase_a_skips_1char,
    };

    // ================================================================
    // Phase B — per-module scope liveness
    // ================================================================
    const phase_b_stats = try allocator.alloc(mangler.ManglerStats, input.modules.len);
    errdefer allocator.free(phase_b_stats);

    // Phase B 는 *이 모듈* 의 Phase A mangled name 만 reserved 로 받는다 (per_mod_reserved).
    // 다른 모듈의 Phase A 이름은 wrapper IIFE 격리로 nested 에서 직접 보이지 않으므로
    // ban 하지 않아도 안전. cross-module reference 는 모두 import binding (module-scope,
    // mangler 내부 reserveNameFor 가 자동 reserve) 또는 wrapper symbol 호출로만 접근.
    for (input.modules, 0..) |m, i| {
        var nested = try mangler.mangle(allocator, .{
            .scopes = m.scopes,
            .symbols = m.symbols,
            .scope_maps = m.scope_maps,
            .references = m.references,
            .source = m.source,
            .skip_symbols = m.module_scope_symbols,
            .external_reserved = &per_mod_reserved[i],
            .external_reserved_global = &global_reserved_set,
        });
        defer nested.deinit();
        phase_b_stats[i] = nested.stats;

        // nested renames 을 unified renames 로 이관 (소유권 이전).
        // OOM 경로에서 아직 이관 못 한 값이 leak 되지 않도록 capacity 를 먼저 확보하고
        // body 는 putAssumeCapacity 만 사용 — put 이 실패할 지점이 없어진다.
        var take = nested.takeRenames();
        const take_count: u32 = @intCast(take.count());
        errdefer {
            var eit = take.iterator();
            while (eit.next()) |e| allocator.free(e.value_ptr.*);
            take.deinit();
        }
        try renames.ensureUnusedCapacity(take_count);

        var it = take.iterator();
        const mod_idx: u32 = @intCast(i);
        while (it.next()) |entry| {
            // RFC #3288 (a) collision invariant: Phase B 가 발급한 nested 이름은
            // per_mod_reserved[i] (= Phase A this-module + cross-module import
            // source mangled 이름 = 그 모듈에서 회피해야 할 외부 top-level 집합)
            // 와 절대 겹치면 안 된다. nextNonReservedBase54Name 의 회피 로직이
            // 이를 보장하므로 정상 경로에선 fire 0. fire 하면 bare scope-hoist
            // 후 같은 top-level scope 에서 동일 이름 → silent broken (예: `.alias`
            // re-export source 가 per_mod_reserved 누락 시). debug 빌드 안전망 —
            // (c) 코어 통합이 1-char 압력을 키우기 전에 정합성을 기계 증명.
            if (builtin.mode == .Debug) {
                if (per_mod_reserved[i].contains(entry.value_ptr.*)) {
                    std.debug.panic(
                        "RFC#3288 collision: module {d} nested '{s}' shadows reserved top-level name (silent-broken)",
                        .{ mod_idx, entry.value_ptr.* },
                    );
                }
            }
            const key: ModuleSymKey = .{ .module_index = mod_idx, .symbol_id = entry.key_ptr.* };
            renames.putAssumeCapacity(key, entry.value_ptr.*);
        }
        take.deinit();
    }

    if (debug_log.enabled(.mangle_audit)) {
        var sum_b_slots: usize = 0;
        var sum_b_skips_1char: usize = 0;
        var sum_b_counter: u32 = 0;
        for (phase_b_stats) |s| {
            sum_b_slots += s.slot_count;
            sum_b_skips_1char += s.reserved_skips_1char;
            sum_b_counter += s.name_counter_final;
        }
        const phase_a_skips: usize = phase_a.name_counter_final - phase_a.slot_count;
        const sum_b_skips: usize = @as(usize, sum_b_counter) - sum_b_slots;
        debug_log.print(.mangle_audit, "PhaseA: slot={d} counter={d} skips={d} skips_1char={d} reserved_size={d} cross_module={d} internal={d} internal_wrapped={d}\n", .{
            phase_a.slot_count,
            phase_a.name_counter_final,
            phase_a_skips,
            phase_a.reserved_skips_1char,
            phase_a.reserved_size,
            phase_a_cross_module,
            phase_a_internal,
            phase_a_internal_wrapped,
        });
        debug_log.print(.mangle_audit, "PhaseB[total]: modules={d} slot_sum={d} counter_sum={d} skips_sum={d} skips_1char_sum={d}\n", .{
            phase_b_stats.len,
            sum_b_slots,
            sum_b_counter,
            sum_b_skips,
            sum_b_skips_1char,
        });
        // per-module breakdown — 1-char 잠식이 가장 큰 모듈 식별. reserved_size 가 큰 모듈은
        // cross-module imports 다수 (의존성 큰 hub) — scope-local mangle 의 fix 후보.
        for (phase_b_stats, 0..) |s, i| {
            if (s.reserved_skips_1char == 0) continue;
            const xmi: usize = if (i < input.modules.len) input.modules[i].cross_module_imports.len else 0;
            const scopes_len: usize = if (i < input.modules.len) input.modules[i].scopes.len else 0;
            debug_log.print(.mangle_audit, "  PhaseB[{d}]: slots={d} skips_1char={d} reserved={d} xmi={d} scopes={d}\n", .{
                i,
                s.slot_count,
                s.reserved_skips_1char,
                s.reserved_size,
                xmi,
                scopes_len,
            });
        }
    }

    return .{
        .renames = renames,
        .allocator = allocator,
        .phase_a = phase_a,
        .phase_b_modules = phase_b_stats,
    };
}

// ============================================================
// Tests
// ============================================================

test "mangleAll: empty input" {
    var result = try mangleAll(std.testing.allocator, .{
        .modules = &.{},
        .top_level_candidates = &.{},
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(result.renames.count())));
    try std.testing.expectEqual(@as(usize, 0), result.phase_a.slot_count);
    try std.testing.expectEqual(@as(usize, 0), result.phase_b_modules.len);
}

test "mangleAll: Phase A renames by frequency" {
    const candidates = [_]TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 0, .name = "rarelyUsed", .ref_count = 1 },
        .{ .module_index = 0, .symbol_id = 1, .name = "hotPath", .ref_count = 100 },
        .{ .module_index = 0, .symbol_id = 2, .name = "medium", .ref_count = 10 },
    };

    var result = try mangleAll(std.testing.allocator, .{
        .modules = &.{},
        .top_level_candidates = &candidates,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 3), @as(u32, @intCast(result.renames.count())));
    // 빈도 1위(hotPath)가 가장 짧은 이름.
    const hot = result.renames.get(.{ .module_index = 0, .symbol_id = 1 }).?;
    const medium = result.renames.get(.{ .module_index = 0, .symbol_id = 2 }).?;
    const rare = result.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    try std.testing.expect(hot.len <= medium.len);
    try std.testing.expect(medium.len <= rare.len);
}

test "mangleAll: global_reserved blocks name assignment" {
    // Base54 첫 이름은 "e" (eternia/...) — 이를 reserved 로 막아 다음 이름이 오게.
    const candidates = [_]TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 0, .name = "longOriginal", .ref_count = 10 },
    };

    var result = try mangleAll(std.testing.allocator, .{
        .modules = &.{},
        .top_level_candidates = &candidates,
        .global_reserved = &.{"e"},
    });
    defer result.deinit();

    const got = result.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    try std.testing.expect(!std.mem.eql(u8, got, "e"));
}

test "mangleAll: Phase B loop runs with empty module (counter carried through)" {
    // semantic 이 빈 모듈이어도 Phase B 루프가 실행되고, 각 모듈 stats 가
    // 할당되며, counter 가 Phase A 값부터 출발하는지 검증. 실제 mangler.mangle
    // 은 scope_count=0 에서 early-return 하므로 rename 없음 — 이 테스트의 목적은
    // "Phase B 경로가 컴파일/실행되고 result 구조가 올바른지" 다.
    const empty_scope_maps: []const std.StringHashMap(usize) = &.{};
    var bitset = try std.DynamicBitSet.initEmpty(std.testing.allocator, 0);
    defer bitset.deinit();

    const modules = [_]ModuleMangleInput{
        .{
            .scopes = &.{},
            .symbols = &.{},
            .scope_maps = empty_scope_maps,
            .references = &.{},
            .source = "",
            .module_scope_symbols = bitset,
        },
    };

    const candidates = [_]TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 0, .name = "alpha", .ref_count = 5 },
    };

    var result = try mangleAll(std.testing.allocator, .{
        .modules = &modules,
        .top_level_candidates = &candidates,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.phase_b_modules.len);
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(result.renames.count())));
    // Phase B 는 실제로 할당한 이름이 없으므로 slot_count 0.
    try std.testing.expectEqual(@as(usize, 0), result.phase_b_modules[0].slot_count);
}

test "mangleAll: identity rename (name already equals base54 head) — no rename entry" {
    // 원본 이름이 base54 의 (reserved 'e'/'m' 을 skip 한 후) 첫 이름 "t" 와 같으면
    // renames 에 기록하지 않음 (no-op).
    const candidates = [_]TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 0, .name = "t", .ref_count = 10 },
    };

    var result = try mangleAll(std.testing.allocator, .{
        .modules = &.{},
        .top_level_candidates = &candidates,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), @as(u32, @intCast(result.renames.count())));
    try std.testing.expectEqual(@as(usize, 1), result.phase_a.slot_count);
    try std.testing.expectEqual(@as(usize, 0), result.phase_a.renamed_symbol_count);
}

test "buildGlobalFrequencyRank: ref_count 내림차순 + 결정적 tie-break" {
    const allocator = std.testing.allocator;
    // ref_count: c=9, a=5, b=5(name tie → 'a'<'b'), d=5(mod tie-break), e=1
    const cands = [_]TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 10, .name = "bb", .ref_count = 5 },
        .{ .module_index = 0, .symbol_id = 11, .name = "aa", .ref_count = 5 },
        .{ .module_index = 0, .symbol_id = 12, .name = "zz", .ref_count = 9 },
        .{ .module_index = 2, .symbol_id = 13, .name = "aa", .ref_count = 5 },
        .{ .module_index = 0, .symbol_id = 14, .name = "qq", .ref_count = 1 },
    };
    var rank = try buildGlobalFrequencyRank(allocator, &cands);
    defer rank.deinit();

    // zz(rc9)=0; aa@mod0(rc5)=1; aa@mod2(rc5,mod tie)=2; bb(rc5)=3; qq(rc1)=4
    try std.testing.expectEqual(@as(u32, 0), rank.get(.{ .module_index = 0, .symbol_id = 12 }).?);
    try std.testing.expectEqual(@as(u32, 1), rank.get(.{ .module_index = 0, .symbol_id = 11 }).?);
    try std.testing.expectEqual(@as(u32, 2), rank.get(.{ .module_index = 2, .symbol_id = 13 }).?);
    try std.testing.expectEqual(@as(u32, 3), rank.get(.{ .module_index = 0, .symbol_id = 10 }).?);
    try std.testing.expectEqual(@as(u32, 4), rank.get(.{ .module_index = 0, .symbol_id = 14 }).?);
}

test "buildGlobalFrequencyRank: 중복 (module,symbol) 은 최우선 rank 유지" {
    const allocator = std.testing.allocator;
    const cands = [_]TopLevelCandidate{
        .{ .module_index = 1, .symbol_id = 7, .name = "xx", .ref_count = 2 },
        .{ .module_index = 0, .symbol_id = 3, .name = "yy", .ref_count = 8 }, // 최다 → rank 0
        .{ .module_index = 1, .symbol_id = 7, .name = "xx", .ref_count = 2 }, // 중복
    };
    var rank = try buildGlobalFrequencyRank(allocator, &cands);
    defer rank.deinit();
    try std.testing.expectEqual(@as(u32, 0), rank.get(.{ .module_index = 0, .symbol_id = 3 }).?);
    try std.testing.expectEqual(@as(u32, 1), rank.get(.{ .module_index = 1, .symbol_id = 7 }).?);
    try std.testing.expectEqual(@as(u32, 2), rank.count());
}
