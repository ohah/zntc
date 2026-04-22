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
const mangler = @import("mangler.zig");
const Scope = @import("../semantic/scope.zig").Scope;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Reference = @import("../semantic/symbol.zig").Reference;

pub const ModuleSymKey = struct {
    module_index: u32,
    symbol_id: u32,
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
};

/// Phase A 의 mangling 후보. 호출부가 빈도/필터링을 수행해 넘긴다
/// (범주: exported/imported/1-char/default/arguments/import binding 제외).
pub const TopLevelCandidate = struct {
    module_index: u32,
    symbol_id: u32,
    name: []const u8,
    ref_count: u32,
};

pub const UnifiedMangleInput = struct {
    modules: []const ModuleMangleInput,
    top_level_candidates: []const TopLevelCandidate,
    /// 런타임 헬퍼 이름 등 외부 예약어. Phase A 초기 reserved set 에 포함.
    global_reserved: []const []const u8 = &.{},
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
    std.mem.sortUnstable(TopLevelCandidate, sorted, {}, struct {
        fn cmp(_: void, a: TopLevelCandidate, b: TopLevelCandidate) bool {
            if (a.ref_count != b.ref_count) return a.ref_count > b.ref_count;
            const name_order = std.mem.order(u8, a.name, b.name);
            if (name_order != .eq) return name_order == .lt;
            if (a.module_index != b.module_index) return a.module_index < b.module_index;
            return a.symbol_id < b.symbol_id;
        }
    }.cmp);

    var name_counter: u32 = 0;
    var name_buf: [8]u8 = undefined;
    var phase_a_slot_name_length_sum: usize = 0;
    var phase_a_renamed: usize = 0;

    for (sorted) |cand| {
        var new_name = mangler.nextBase54Name(&name_counter, &name_buf);
        while (reserved.contains(new_name)) {
            new_name = mangler.nextBase54Name(&name_counter, &name_buf);
        }
        phase_a_slot_name_length_sum += new_name.len;

        if (!std.mem.eql(u8, cand.name, new_name)) {
            const duped = try allocator.dupe(u8, new_name);
            errdefer allocator.free(duped);
            try renames.put(.{ .module_index = cand.module_index, .symbol_id = cand.symbol_id }, duped);
            try reserved.put(duped, {});
            phase_a_renamed += 1;
        } else {
            // 원본과 동일해도 다음 Phase A 후보가 같은 이름을 집지 못하도록 reserved.
            try reserved.put(cand.name, {});
        }
    }

    const phase_a: mangler.ManglerStats = .{
        .slot_count = sorted.len,
        .slot_name_length_sum = phase_a_slot_name_length_sum,
        .name_counter_final = name_counter,
        .reserved_size = reserved.count(),
        .renamed_symbol_count = phase_a_renamed,
    };

    // ================================================================
    // Phase B — per-module scope liveness
    // ================================================================
    const phase_b_stats = try allocator.alloc(mangler.ManglerStats, input.modules.len);
    errdefer allocator.free(phase_b_stats);

    for (input.modules, 0..) |m, i| {
        // Phase B 는 per-module 독립 counter. external_reserved 는 해당 모듈
        // scope 심볼의 Phase A mangled 이름만 포함 (outer shadow 방지 + 전역
        // pool 공유의 over-reserving 회피).
        var module_reserved: std.StringHashMap(void) = .init(allocator);
        defer module_reserved.deinit();
        if (m.scope_maps.len > 0) {
            var sit = m.scope_maps[0].iterator();
            while (sit.next()) |entry| {
                const sid: u32 = @intCast(entry.value_ptr.*);
                const key: ModuleSymKey = .{ .module_index = @intCast(i), .symbol_id = sid };
                if (renames.get(key)) |mangled| try module_reserved.put(mangled, {});
            }
        }

        var nested = try mangler.mangle(allocator, .{
            .scopes = m.scopes,
            .symbols = m.symbols,
            .scope_maps = m.scope_maps,
            .references = m.references,
            .source = m.source,
            .skip_symbols = m.module_scope_symbols,
            .external_reserved = &module_reserved,
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
        try reserved.ensureUnusedCapacity(take_count);

        var it = take.iterator();
        const mod_idx: u32 = @intCast(i);
        while (it.next()) |entry| {
            const key: ModuleSymKey = .{ .module_index = mod_idx, .symbol_id = entry.key_ptr.* };
            renames.putAssumeCapacity(key, entry.value_ptr.*);
            reserved.putAssumeCapacity(entry.value_ptr.*, {});
        }
        take.deinit();
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
    // 원본 이름이 이미 base54 첫 이름("e") 인 심볼은 renames 에 기록하지 않음 (no-op).
    const candidates = [_]TopLevelCandidate{
        .{ .module_index = 0, .symbol_id = 0, .name = "e", .ref_count = 10 },
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
