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

pub const ScopeId = scope_mod.ScopeId;

/// scope_id → outer-ref symbol_id set.
///
/// key 는 `ScopeId.toIndex()` (u32), value 는 `DynamicBitSet` (symbol_id 인덱스 bit).
/// caller (analyzer) 가 build 후 mangler input 에 borrow 로 전달. mangler 가 lookup 시
/// `get(scope_id)` 가 null 이면 free-ref 없음 또는 분석 미수행 — 보수 fallback (현 동작).
///
/// 메모리: lib 별 평균 nested scope 수 × 평균 free-var symbol 수. zod ~수십 scope ×
/// 수십 symbol = bitset 당 수 byte, 총 KB 미만. 큰 lib 도 MB 미만 예상.
pub const FreeVarMap = std.AutoHashMap(u32, std.DynamicBitSet);

/// R1-a kill-switch env flag. PR-2 단계는 항상 false 동작 (analyzer build path 없음).
/// PR-2-b 부터 환경변수 `ZNTC_R1A_FREEVAR_INFRA` 로 활성화. PR-3 의 mangler reuse 는
/// 별도 flag `ZNTC_R1A_PRECISE_REUSE` 로 게이트 — 두 단계 독립 측정.
pub const FREEVAR_INFRA_ENV = "ZNTC_R1A_FREEVAR_INFRA";

test "FreeVarMap type compiles" {
    var map = FreeVarMap.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.count());
}
