//! ZNTC Minify Renamer — esbuild `renamer.go` MinifyRenamer 1:1 이식
//!
//! RFC #3391 / 트래킹 이슈 #3392, **PR-2**.
//!
//! PR-1(`nested_slots.zig`)이 부여한 `nested_scope_slot` 위에, esbuild
//! `MinifyRenamer` 의 **단일 per-namespace 빈도 풀** 이름 발급을 이식한다.
//!
//! ## 격차의 근본 (왜 이게 유일 레버인가)
//!
//! ZNTC 현 2-phase: Phase A 가 *전* top-level 을 빈도순으로 먼저 mangle 해
//! 54개 1-char 풀을 선점 → Phase B per-module nested 는 2-char fallback.
//!
//! esbuild MinifyRenamer: namespace 별 `slots[ns]` = `[nested 0..N) ++
//! [top-level N..)` 를 **하나의 count 내림차순 시퀀스**로 정렬해 `nextName++`
//! base54 발급. 결과:
//!   - 고빈도 nested 슬롯이 저빈도 top-level 보다 짧은 이름을 얻는다 (격차 회수).
//!   - 모든 슬롯이 단조 증가 카운터로 *고유* 이름 → nested(임의 모듈) 와
//!     top-level 이름이 절대 같지 않음 → shadow 구성적 불가. 그래서 ZNTC 의
//!     `per_mod_reserved` selective-broadcast(#1760) 자체가 불필요해진다
//!     (더 작으면서 *동시에* 더 안전).
//!   - 서로 다른 모듈의 nested slot N 은 같은 이름을 공유하지만 (disjoint
//!     function scope, 동시 live 불가) — PR-1 의 형제-재사용 그래프 컬러링과
//!     동일 안전 논거.
//!
//! ## PR-2 범위 (flag off — behavior 무변경)
//!
//! `mangleAllNested` 는 `unified_mangler.mangleAll` 과 동일 입출력. env
//! `ZNTC_NESTED_SLOTS=1` 일 때만 `mangleAll` 이 이리로 dispatch 한다. 기본
//! (flag off) 은 기존 Phase A/B 경로 그대로 → 번들 출력 byte-identical.
//! flag on 전수 smoke + 압축률 게이트는 PR-3.
//!
//! ZNTC ↔ esbuild: `MinifyRenamer.slots[ns]`→`slots`(default ns 만 — ZNTC
//! 는 label/private 비심볼), `AccumulateSymbolCount`→nested 는 ref_count
//! 합산/top-level 은 candidate.ref_count, `AllocateTopLevelSymbolSlots`→
//! 직렬 append, `AssignNamesByFrequency`/`NumberToMinifiedName`→ZNTC
//! base54 + `nextNonReservedBase54NameTwo`(예약 skip), `NameForSymbol`→
//! rename map (`ModuleSymKey`).

const std = @import("std");
const builtin = @import("builtin");
const um = @import("unified_mangler.zig");
const nested = @import("nested_slots.zig");
const mangler = @import("mangler.zig");
const symbol_mod = @import("../semantic/symbol.zig");
const Symbol = symbol_mod.Symbol;

// env `ZNTC_NESTED_SLOTS` presence gate (default off). transpile.zig 의
// fast-path flag 와 동일 관례 — std.once 로 thread-safe 1회 캐시, allocator
// 불필요, WASI 가드.
var nested_slots_once = std.once(computeNestedSlotsEnabled);
var nested_slots_value: bool = false;

fn computeNestedSlotsEnabled() void {
    if (comptime builtin.os.tag == .wasi and !builtin.link_libc) {
        nested_slots_value = false;
        return;
    }
    nested_slots_value = std.process.hasEnvVarConstant("ZNTC_NESTED_SLOTS");
}

pub fn enabled() bool {
    nested_slots_once.call();
    return nested_slots_value;
}

const Slot = struct {
    count: u32 = 0,
    /// 발급된 이름. owned (slots 해제 시 free) — renames 에는 재-dupe.
    name: []const u8 = "",
};

const SlotOrder = struct {
    idx: u32,
    count: u32,
};

/// esbuild `slotAndCountArray.Less`: count 내림차순, 동률은 slot index 오름차순.
fn slotOrderLessThan(_: void, a: SlotOrder, b: SlotOrder) bool {
    if (a.count != b.count) return a.count > b.count;
    return a.idx < b.idx;
}

/// `new_name` 이 비었거나 원본과 같으면 no-op, 아니면 dupe 해서 renames 에
/// put. nested/top-level 두 경로 공용 (esbuild NameForSymbol 의 동일 분기).
fn putRename(
    allocator: std.mem.Allocator,
    renames: *std.AutoHashMap(um.ModuleSymKey, []const u8),
    key: um.ModuleSymKey,
    orig: []const u8,
    new_name: []const u8,
) !bool {
    if (new_name.len == 0 or std.mem.eql(u8, orig, new_name)) return false;
    const duped = try allocator.dupe(u8, new_name);
    errdefer allocator.free(duped);
    try renames.put(key, duped);
    return true;
}

/// `unified_mangler.mangleAll` 의 nested-slot 대체 경로. 동일 입출력 계약.
pub fn mangleAllNested(
    allocator: std.mem.Allocator,
    input: um.UnifiedMangleInput,
) !um.UnifiedMangleResult {
    var renames: std.AutoHashMap(um.ModuleSymKey, []const u8) = .init(allocator);
    errdefer {
        var vit = renames.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        renames.deinit();
    }

    // ── Phase 1: per-module nested slot 부여 (mutable copy 위에서) ──
    // ModuleMangleInput.symbols 는 const — 기존 경로 계약 유지 위해 이 경로
    // 전용으로 mutable dup. flag on (PR-3 측정) 때만 발생하는 비용.
    const mod_syms = try allocator.alloc([]Symbol, input.modules.len);
    var allocated: usize = 0;
    defer {
        for (mod_syms[0..allocated]) |ms| allocator.free(ms);
        allocator.free(mod_syms);
    }
    var first_top: u32 = 0; // = max over modules of nested default slot count
    for (input.modules, 0..) |m, i| {
        const dup = try allocator.dupe(Symbol, m.symbols);
        mod_syms[i] = dup;
        allocated = i + 1;
        const counts = try nested.assignNestedScopeSlots(allocator, m.scopes, dup, m.scope_maps, m.source);
        const c = counts.get(.default);
        if (c > first_top) first_top = c;
    }

    // ── Phase 2: slots 배열 — [0, first_top) = nested, 이후 top-level append ──
    var slots: std.ArrayList(Slot) = .empty;
    defer {
        for (slots.items) |s| if (s.name.len > 0) allocator.free(s.name);
        slots.deinit(allocator);
    }
    try slots.appendNTimes(allocator, .{}, first_top);

    // nested count 누적 — 서로 다른 모듈의 같은 slot 번호는 동일 이름을
    // 공유하므로 count 를 합산 (esbuild atomic add 의 직렬 등가).
    for (input.modules, 0..) |m, i| {
        for (mod_syms[i]) |sym| {
            const slot = sym.nested_scope_slot orelse continue;
            if (slot >= first_top) continue; // 방어 (valid nested 는 항상 < first_top)
            if (nested.slotNamespace(sym, sym.nameText(m.source)) != .default) continue;
            slots.items[slot].count += sym.reference_count;
        }
    }

    // ── Phase 3: top-level slot 직렬 할당 (esbuild AllocateTopLevelSymbolSlots) ──
    // caller(linker.collectUnifiedInput) 가 이미 renamable 만 candidate 로 거름.
    // 결정적 순서 — 기존 Phase A 와 동일 비교자 재사용.
    const sorted_cands = try allocator.alloc(um.TopLevelCandidate, input.top_level_candidates.len);
    defer allocator.free(sorted_cands);
    @memcpy(sorted_cands, input.top_level_candidates);
    std.mem.sortUnstable(um.TopLevelCandidate, sorted_cands, {}, um.candidateLessThan);

    var top_to_slot: std.AutoHashMap(um.ModuleSymKey, u32) = .init(allocator);
    defer top_to_slot.deinit();
    for (sorted_cands) |c| {
        const key: um.ModuleSymKey = .{ .module_index = c.module_index, .symbol_id = c.symbol_id };
        const gop = try top_to_slot.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(slots.items.len);
            try slots.append(allocator, .{ .count = c.ref_count });
        } else {
            slots.items[gop.value_ptr.*].count += c.ref_count;
        }
    }

    // ── Phase 4: 빈도순 이름 발급 (esbuild AssignNamesByFrequency) ──
    const order = try allocator.alloc(SlotOrder, slots.items.len);
    defer allocator.free(order);
    for (slots.items, 0..) |s, i| order[i] = .{ .idx = @intCast(i), .count = s.count };
    std.mem.sortUnstable(SlotOrder, order, {}, slotOrderLessThan);

    var reserved: std.StringHashMap(void) = .init(allocator);
    defer reserved.deinit();
    for (input.global_reserved) |r| try reserved.put(r, {});

    var counter: u32 = 0;
    var buf: [8]u8 = undefined;
    var skips_1char: usize = 0;
    var name_len_sum: usize = 0;
    for (order) |o| {
        // 단조 카운터 → 슬롯마다 고유 이름. reserved/예약어만 skip
        // (직전 발급 이름은 reserved 에 안 넣음 — 카운터 단조라 불필요).
        const name = mangler.nextNonReservedBase54NameTwo(&counter, &buf, &reserved, null, &skips_1char);
        slots.items[o.idx].name = try allocator.dupe(u8, name);
        name_len_sum += name.len;
    }

    // ── Phase 5: rename map (esbuild NameForSymbol) ──
    var renamed: usize = 0;
    for (input.modules, 0..) |m, i| {
        const mod_idx: u32 = @intCast(i);
        for (mod_syms[i], 0..) |sym, sid| {
            const slot = sym.nested_scope_slot orelse continue;
            if (slot >= first_top) continue;
            const orig = sym.nameText(m.source);
            if (nested.slotNamespace(sym, orig) != .default) continue;
            const key: um.ModuleSymKey = .{ .module_index = mod_idx, .symbol_id = @intCast(sid) };
            if (try putRename(allocator, &renames, key, orig, slots.items[slot].name)) renamed += 1;
        }
    }
    for (input.top_level_candidates) |c| {
        const key: um.ModuleSymKey = .{ .module_index = c.module_index, .symbol_id = c.symbol_id };
        const slot = top_to_slot.get(key) orelse continue;
        if (try putRename(allocator, &renames, key, c.name, slots.items[slot].name)) renamed += 1;
    }

    return .{
        .renames = renames,
        .allocator = allocator,
        .phase_a = .{
            .slot_count = slots.items.len,
            .slot_name_length_sum = name_len_sum,
            .name_counter_final = counter,
            .reserved_size = reserved.count(),
            .renamed_symbol_count = renamed,
            .reserved_skips_1char = skips_1char,
        },
        .phase_b_modules = &.{},
    };
}

// ============================================================
// 유닛 테스트 — esbuild MinifyRenamer fixture 동치
// ============================================================

const testing = std.testing;
const Span = @import("../lexer/token.zig").Span;
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

const TSym = struct { name: []const u8, scope: u32, refs: u32 };

/// 단일 모듈 fixture. `cands`/`reserved` 옵션으로 통합-풀·예약 테스트까지 한
/// 헬퍼로 수렴 (인라인 셋업 중복 제거). 결과는 (symbol_id → new_name) 조회용.
fn runModule(
    allocator: std.mem.Allocator,
    parents: []const u32,
    syms: []const TSym,
    cands: []const um.TopLevelCandidate,
    reserved: []const []const u8,
) !um.UnifiedMangleResult {
    var scopes = try allocator.alloc(Scope, parents.len);
    defer allocator.free(scopes);
    for (parents, 0..) |p, i| scopes[i] = .{
        .parent = if (p == 0xFFFFFFFF) ScopeId.none else @enumFromInt(p),
        .kind = if (i == 0) .module else .block,
        .is_strict = true,
    };

    var symbols = try allocator.alloc(Symbol, syms.len);
    defer allocator.free(symbols);
    for (syms, 0..) |s, i| symbols[i] = .{
        .name = Span{ .start = 0, .end = 0 },
        .scope_id = @enumFromInt(s.scope),
        .kind = .variable_let,
        .declaration_span = Span{ .start = 0, .end = 0 },
        .reference_count = s.refs,
        .synthetic_name = s.name,
    };

    var scope_maps = try allocator.alloc(std.StringHashMap(usize), parents.len);
    defer {
        for (scope_maps) |*mp| mp.deinit();
        allocator.free(scope_maps);
    }
    for (scope_maps) |*mp| mp.* = std.StringHashMap(usize).init(allocator);
    for (syms, 0..) |s, i| try scope_maps[s.scope].put(s.name, i);

    var bs = try std.DynamicBitSet.initEmpty(allocator, 0);
    defer bs.deinit();
    const mods = [_]um.ModuleMangleInput{.{
        .scopes = scopes,
        .symbols = symbols,
        .scope_maps = scope_maps,
        .references = &.{},
        .source = "",
        .module_scope_symbols = bs,
    }};

    return mangleAllNested(allocator, .{
        .modules = &mods,
        .top_level_candidates = cands,
        .global_reserved = reserved,
    });
}

test "고빈도 nested slot 이 더 짧은 이름 (빈도순 — 1-char 풀 고갈로 엄밀)" {
    const a = testing.allocator;
    // 한 fn 에 nested 70개: 고빈도 1개(ref 10000) + 저빈도 69개(ref 1).
    // base54 1-char 풀(~52)을 초과시켜 빈도 *우선순위*를 강제 검증 — 고빈도는
    // 1-char, 최저빈도 일부는 2-char 가 되어야 한다.
    var syms: [70]TSym = undefined;
    syms[0] = .{ .name = "zHot", .scope = 1, .refs = 10000 };
    var names: [70][3]u8 = undefined;
    for (1..70) |i| {
        names[i] = .{ 'v', @intCast('a' + (i - 1) % 26), @intCast('0' + (i - 1) / 26) };
        syms[i] = .{ .name = &names[i], .scope = 1, .refs = 1 };
    }
    var r = try runModule(a, &.{ 0xFFFFFFFF, 0 }, &syms, &.{}, &.{});
    defer r.deinit();
    const hot = r.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    try testing.expectEqual(@as(usize, 1), hot.len); // 최고빈도 → 1-char
    var max_len: usize = 0;
    for (1..70) |i| {
        const n = r.renames.get(.{ .module_index = 0, .symbol_id = @intCast(i) }).?;
        max_len = @max(max_len, n.len);
    }
    try testing.expect(max_len >= 2); // 풀 고갈 → 저빈도 일부는 2-char (빈도순 실증)
}

test "형제 nested slot 은 같은 이름 공유 (disjoint scope 안전)" {
    const a = testing.allocator;
    // module → {1:fnA(x), 2:fnB(y)} — 형제, 둘 다 slot 0 → 같은 이름
    var r = try runModule(a, &.{ 0xFFFFFFFF, 0, 0 }, &.{
        .{ .name = "xx", .scope = 1, .refs = 5 },
        .{ .name = "yy", .scope = 2, .refs = 5 },
    }, &.{}, &.{});
    defer r.deinit();
    const x = r.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    const y = r.renames.get(.{ .module_index = 0, .symbol_id = 1 }).?;
    try testing.expectEqualStrings(x, y);
}

test "nested + top-level 통합 빈도 풀: 고빈도 nested 가 저빈도 top-level 보다 우선" {
    const a = testing.allocator;
    // hotNested(ref 100) + coldTopLevel(ref 1). 통합 풀이면 nested 가 먼저
    // 발급(1-char). 구 Phase-A-독점 모델이면 top-level 이 선점했을 자리.
    var r = try runModule(a, &.{ 0xFFFFFFFF, 0 }, &.{
        .{ .name = "hotNested", .scope = 1, .refs = 100 },
    }, &.{
        .{ .module_index = 0, .symbol_id = 100, .name = "coldTopLevel", .ref_count = 1 },
    }, &.{});
    defer r.deinit();
    const hot = r.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    const top = r.renames.get(.{ .module_index = 0, .symbol_id = 100 }).?;
    try testing.expectEqual(@as(usize, 1), hot.len);
    // 고빈도 nested 가 저빈도 top-level 보다 짧거나 같고, 둘은 다른 이름.
    try testing.expect(hot.len <= top.len);
    try testing.expect(!std.mem.eql(u8, hot, top));
}

test "multi-module: 같은 nested slot 번호는 모듈 간 count 합산" {
    const a = testing.allocator;
    // modA.fn(s ref=2), modB.fn(s ref=2) — 둘 다 nested slot 0 → 합산 count=4.
    // top-level candidate ref=3. 합산(4)>top(3) → nested 가 먼저(더 짧/같음).
    // 합산이 깨졌다면 각 모듈 slot0 count=2 < top 3 이라 top 이 먼저였을 것.
    var sa = [_]Scope{
        .{ .parent = ScopeId.none, .kind = .module, .is_strict = true },
        .{ .parent = @enumFromInt(0), .kind = .block, .is_strict = true },
    };
    var sb = sa;
    var symsA = [_]Symbol{.{ .name = Span{ .start = 0, .end = 0 }, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = Span{ .start = 0, .end = 0 }, .reference_count = 2, .synthetic_name = "aVar" }};
    var symsB = [_]Symbol{.{ .name = Span{ .start = 0, .end = 0 }, .scope_id = @enumFromInt(1), .kind = .variable_let, .declaration_span = Span{ .start = 0, .end = 0 }, .reference_count = 2, .synthetic_name = "bVar" }};
    var smA = try a.alloc(std.StringHashMap(usize), 2);
    var smB = try a.alloc(std.StringHashMap(usize), 2);
    defer {
        for (smA) |*mp| mp.deinit();
        for (smB) |*mp| mp.deinit();
        a.free(smA);
        a.free(smB);
    }
    for (smA) |*mp| mp.* = std.StringHashMap(usize).init(a);
    for (smB) |*mp| mp.* = std.StringHashMap(usize).init(a);
    try smA[1].put("aVar", 0);
    try smB[1].put("bVar", 0);
    var b0 = try std.DynamicBitSet.initEmpty(a, 0);
    defer b0.deinit();
    var b1 = try std.DynamicBitSet.initEmpty(a, 0);
    defer b1.deinit();
    const mods = [_]um.ModuleMangleInput{
        .{ .scopes = &sa, .symbols = &symsA, .scope_maps = smA, .references = &.{}, .source = "", .module_scope_symbols = b0 },
        .{ .scopes = &sb, .symbols = &symsB, .scope_maps = smB, .references = &.{}, .source = "", .module_scope_symbols = b1 },
    };
    const cands = [_]um.TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 50, .name = "topThree", .ref_count = 3 },
    };
    var r = try mangleAllNested(a, .{ .modules = &mods, .top_level_candidates = &cands });
    defer r.deinit();

    const av = r.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    const bv = r.renames.get(.{ .module_index = 1, .symbol_id = 0 }).?;
    const tv = r.renames.get(.{ .module_index = 0, .symbol_id = 50 }).?;
    try testing.expectEqualStrings(av, bv); // 모듈 간 slot 0 공유 → 동일 이름
    try testing.expect(av.len <= tv.len); // 합산 4 > 3 → nested 우선
    try testing.expect(!std.mem.eql(u8, av, tv));
}

test "global_reserved 이름은 발급에서 skip" {
    const a = testing.allocator;
    var r = try runModule(a, &.{ 0xFFFFFFFF, 0 }, &.{
        .{ .name = "someVar", .scope = 1, .refs = 9 },
    }, &.{}, &.{ "t", "n" }); // base54 초반 이름 막기
    defer r.deinit();
    const got = r.renames.get(.{ .module_index = 0, .symbol_id = 0 }).?;
    try testing.expect(!std.mem.eql(u8, got, "t"));
    try testing.expect(!std.mem.eql(u8, got, "n"));
}

test "빈 입력 안전" {
    var r = try mangleAllNested(testing.allocator, .{ .modules = &.{}, .top_level_candidates = &.{} });
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(r.renames.count())));
}
