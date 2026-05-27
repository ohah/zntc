//! R1-a free-var (closure capture) 분석 — RFC `RFC_MANGLER_SAFE_C2.md` §4.2 PR-2 inert infra.
//!
//! 각 nested scope 가 *사용하는 outer scope 의 symbol set* 을 명시적 bitset 으로 보관.
//! 현 main 의 `mangler.markAncestorPath` (전체 ancestor 마킹, RFC §2.1) 보수성을 R1-a PR-3
//! 에서 *참조된 outer symbol 만* 회피하도록 좁히기 위한 입력 자료.
//!
//! **PR-2 단계는 inert** — `FreeVarMap` type 정의 + mangler input 의 `free_vars_per_scope`
//! field (default null) 추가만. analyzer 가 build 하는 PR-2-b, mangler 가 사용하는 PR-3 는
//! 별도 sub-PR. PR-2 자체는 코드 path 변경 0 → byte-identical 자동 보장.

const std = @import("std");
const scope_mod = @import("scope.zig");
const symbol_mod = @import("symbol.zig");

pub const ScopeId = scope_mod.ScopeId;
pub const Scope = scope_mod.Scope;
pub const Symbol = symbol_mod.Symbol;
pub const Reference = symbol_mod.Reference;

/// scope_id → outer-ref symbol_id set.
///
/// key 는 `ScopeId.toIndex()` (u32), value 는 `DynamicBitSet` (symbol_id 인덱스 bit).
/// caller (analyzer) 가 build 후 mangler input 에 borrow 로 전달. mangler 가 lookup 시
/// `get(scope_id)` 가 null 이면 free-ref 없음 또는 분석 미수행 — 보수 fallback (현 동작).
///
/// 메모리: lib 별 평균 nested scope 수 × 평균 free-var symbol 수. zod ~수십 scope ×
/// 수십 symbol = bitset 당 수 byte, 총 KB 미만. 큰 lib 도 MB 미만 예상.
pub const FreeVarMap = std.AutoHashMap(u32, std.DynamicBitSet);

/// R1-a kill-switch env flag. PR-2-a 단계는 inert (analyzer build path 없음).
/// PR-2-b 부터 환경변수 `ZNTC_R1A_FREEVAR_INFRA` 로 활성화. PR-3 의 mangler reuse 는
/// 별도 flag `ZNTC_R1A_PRECISE_REUSE` 로 게이트 — 두 단계 독립 측정.
pub const FREEVAR_INFRA_ENV = "ZNTC_R1A_FREEVAR_INFRA";

/// `descendant` 가 `maybe_ancestor` 의 *strict descendant* (= maybe_ancestor 자체 아님,
/// parent 체인 따라 도달 가능) 인지. 같은 scope 는 false (outer-ref 아님 — 자기 scope
/// 내 ref 는 closure capture 아님). mangler.markScopeSubtree 의 보수 대체로 PR-3 에서
/// "ref 의 decl_scope 가 outer 인지" 판정에 사용.
pub fn isStrictDescendant(scopes: []const Scope, maybe_ancestor: ScopeId, descendant: ScopeId) bool {
    if (maybe_ancestor.isNone() or descendant.isNone()) return false;
    if (@intFromEnum(maybe_ancestor) == @intFromEnum(descendant)) return false;
    var cur = descendant;
    const idx = cur.toIndex();
    if (idx >= scopes.len) return false;
    cur = scopes[idx].parent;
    while (!cur.isNone()) {
        if (@intFromEnum(cur) == @intFromEnum(maybe_ancestor)) return true;
        const i = cur.toIndex();
        if (i >= scopes.len) return false;
        cur = scopes[i].parent;
    }
    return false;
}

/// 현재 환경에서 R1-a free-var infra 가 활성화됐는지. env `ZNTC_R1A_FREEVAR_INFRA`
/// 설정값 무관 *존재* 만 검사 (`=0`/`=false` 도 활성). 단순 toggle 의도.
/// allocator 가 필요한 이유: zig `std.process.getEnvVarOwned` 는 owned slice 반환.
/// 호출 빈도 = analyze() 호출당 1회 (= 파일당 1회 빌드) → 매번 호출도 overhead 무시 가능.
pub fn isInfraEnabled(allocator: std.mem.Allocator) bool {
    const v = std.process.getEnvVarOwned(allocator, FREEVAR_INFRA_ENV) catch return false;
    defer allocator.free(v);
    return v.len > 0;
}

/// nested scope 별 outer-ref symbol bitset 을 build. references 1회 순회로
/// `O(refs × ancestor_depth)`. ancestor_depth 는 일반적 lib 에서 <10.
///
/// `symbols` / `scopes` / `references` 는 SemanticAnalyzer 의 결과 slice. caller 가
/// 소유. 반환된 FreeVarMap 은 caller 가 `freeFreeVarMap` 으로 해제 필요.
///
/// 안전: env flag 미설정 시 caller 가 `isInfraEnabled` 확인 후 호출. 본 함수 자체는
/// flag 검사 안 함 — 호출자가 게이트 (test 에서는 직접 호출 가능).
pub fn buildFreeVarMap(
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    symbols: []const Symbol,
    references: []const Reference,
) std.mem.Allocator.Error!FreeVarMap {
    var map = FreeVarMap.init(allocator);
    errdefer freeFreeVarMap(&map);

    const symbol_count = symbols.len;
    if (symbol_count == 0) return map;

    for (references) |ref| {
        const sym_idx: u32 = @intFromEnum(ref.symbol_id);
        if (sym_idx >= symbol_count) continue;
        const decl_scope = symbols[sym_idx].scope_id;
        if (!isStrictDescendant(scopes, decl_scope, ref.scope_id)) continue;

        const key = ref.scope_id.toIndex();
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = try std.DynamicBitSet.initEmpty(allocator, symbol_count);
        }
        gop.value_ptr.set(sym_idx);
    }
    return map;
}

/// `buildFreeVarMap` 결과 해제. entry 별 DynamicBitSet + HashMap 자체.
pub fn freeFreeVarMap(map: *FreeVarMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    map.deinit();
}

test "FreeVarMap type compiles" {
    var map = FreeVarMap.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "isStrictDescendant — none / 자기 자신 / 직속 부모 / 깊은 부모" {
    const none = ScopeId.none;
    const s0: ScopeId = @enumFromInt(0);
    const s1: ScopeId = @enumFromInt(1);
    const s2: ScopeId = @enumFromInt(2);
    const scopes = [_]Scope{
        .{ .parent = none, .kind = .module, .is_strict = false },
        .{ .parent = s0, .kind = .function, .is_strict = false },
        .{ .parent = s1, .kind = .block, .is_strict = false },
    };
    try std.testing.expect(!isStrictDescendant(&scopes, none, s1));
    try std.testing.expect(!isStrictDescendant(&scopes, s0, none));
    try std.testing.expect(!isStrictDescendant(&scopes, s1, s1));
    try std.testing.expect(isStrictDescendant(&scopes, s0, s1));
    try std.testing.expect(isStrictDescendant(&scopes, s0, s2));
    try std.testing.expect(isStrictDescendant(&scopes, s1, s2));
    try std.testing.expect(!isStrictDescendant(&scopes, s2, s0));
    try std.testing.expect(!isStrictDescendant(&scopes, s2, s1));
}
