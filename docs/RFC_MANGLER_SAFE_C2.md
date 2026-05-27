# RFC: Mangler R1-a — precise free-var 분석으로 c2 안전화

상태: **DRAFT · 박제 충돌 영역 의도적 재시도** · 분류: R&D spike
관련: `RFC_MANGLER_SIZE_GAP_CLOSED.md` (§3 c2/M2 NO-GO) · `project_minify_gap_S_series` · `project_nested_scope_renamer_epic` · `project_object_key_unquote_win`

## 0. 박제 충돌 명시 (RFC 머지 전 합의)

본 RFC 는 **이미 측정으로 NO-GO 가 확정된 영역의 의도적 재시도**다:

- `RFC_MANGLER_SIZE_GAP_CLOSED.md §3` 가 c2/M2 를 *"전부 NO-GO·재시도 금지"* 로 종결
- `project_minify_gap_S_series` 가 c2 (PR2) 측정 결과 (zod +3.2KB / effect +61KB) 를 *"재시도 절대 금지"* 로 박제
- `project_combined_scope_tree_rfc` / `project_nested_scope_renamer_epic` 도 mangler 코어 알고리즘 회수 영역 NO-GO 박제

본 RFC 의 R1-a 가설이 c2 의 실패 root cause (위험 A) 를 정밀 free-var 분석으로 해결 가능하다는 미시도 영역 (reference 0) 이라는 점에서 박제 영역과 *부분적으로 다른* 새 시도다. 단:

- **본 RFC 의 measure-first 게이트 미달 시 본 RFC 자체가 NO-GO 박제로 격하 + 영구 종결**
- **게이트 통과해도 corpus -1.7% (도달 불가 낙관) 도달 시까지는 PoC 단계 머지 금지**
- **사용자 명령 "임시방편 금지 + 루트커즈 수정" 준수** — 측정 결과가 분명한 root cause 식별 + safe 화 입증해야 진행

## 1. 배경 — c2/M2 실패 정리

### 1.1 ZNTC mangler 2-phase 구조

- **Phase A** (`src/codegen/unified_mangler.zig`): cross-module top-level. 전역 counter + reserved + 빈도순 base54
- **Phase B** (`src/codegen/mangler.zig`): per-module nested. flat per-module mangle

vue 같이 bare scope-hoist + module 수 많은 lib 에서:
- Phase A 가 1글자 풀 (54) 을 전역 frequency 순으로 hot top-level 에 선점
- `linker.zig:799-816` 가 *모든 scope* 의 1글자 식별자를 reserved 등록 → nested scope 의 식별자는 2-3-5글자로 밀림
- 결과: vue +24KB rspack 격차, zod 1.13x, rxjs 1.09x, zlib 1.15x 등

### 1.2 c2 (RFC #3288) 시도

`unified_mangler` 안 contain 구현:
- cross_module_ref_set un-gate
- internal_set + Phase A internal skip
- Phase B 가 internal 을 reuse (eff_skip)
- `precise_liveness` (#3335 infra) 연결

결과 측정 (`spike/c2-mangler`):
- zod 306,815 → 310,065 (+3,250)
- effect 1,036,156 → 1,097,353 (+61,197 / +5.9%)
- rxjs +254
- collision assert fire **0** (정확성 안전)
- **size 회귀 → revert, 미머지**

### 1.3 M2 (frequency-보존 slot pool) 시도

c2 의 size 회귀가 *frequency 손실* 가설:
- `buildGlobalFrequencyRank` + `candidateLessThan` (#3338) + `mangler global_freq_rank` (#3339) 추가
- PR-3 (flag-gated): internal top-level → Phase B + precise_liveness + global_rank 주입

결과:
- zod +3,250 (c2 와 동일)
- effect +64,771 (c2 보다 더 나쁨)
- rxjs +254
- **freq 보존해도 회귀 → revert, 미머지**

### 1.4 c2/M2 실패 root cause 분석 (메모리 박제 인용)

`project_minify_gap_S_series` §c2 단락:
> 근본 (확정): per-module Phase B slot pool 은 Phase A 단일 전역 counter 의 *cross-module 이름 조정* 을 대체 불가. global_freq_rank 는 모듈 *내부* slot 정렬만 재배치 — 모듈 간 전역 이름 공유는 복원 못 함. precise_liveness 도 top-level 광범위 참조엔 무력.

## 2. c2 의 진짜 root cause 재정의 — "위험 A"

c2 의 size 회귀를 *frequency 손실* 이 아닌 *collision 회피 보수성* 으로 재해석:

### 2.1 bare scope-hoist 의 nested-outer collision

bare scope-hoist (zod/three/effect/lodash 등 현대 dist 지배적) 에서:
- top-level scope 는 module 전체 (scope_id=0)
- nested scope (예: `function f(){let i;...}`) 의 `i` 는 outer top-level 의 `i` 와 lexical shadow 관계

c2 가 Phase B 에서 nested 의 1글자 풀 재시작 시:
- 만약 nested 의 free-var 분석이 정확하지 않으면 outer top-level internal 이름과 collision 발생 가능
- ZNTC 의 현재 Phase B `markScopeSubtree(0)` 는 *top-level 의 모든 symbol 을 alive 로* 마킹 → nested 가 1글자 풀 reuse 시도해도 outer top-level 의 모든 1글자 와 disjoint 필요 → 사실상 reuse 불가
- 결과: 보수적 fallback 으로 2-3글자

precise_liveness (#3335) 는 references ancestor-path 정밀화로 *일부* nested 가 1글자 reuse 가능하게 한다. 단:
- top-level (scope 0) 이 `markScopeSubtree(0)` = 모듈 전체 alive → 항상 nested 와 disjoint 실패
- 단순 skip_symbols 해제로는 효과 0
- precise_liveness 가 이를 해소하지만 **markAncestorPath 가 많은 scope 마킹 → liveness 비대 → graph-coloring 재사용 거의 0**

→ c2 의 실패는 *frequency 손실* 이 아닌 *outer free-var 분석 부정확성 → 보수적 markAncestorPath* 가 root cause.

### 2.2 esbuild renamer 의 reference 패턴

esbuild `MinifyRenamer` (`renamer.go:AssignNestedScopeSlots`):
- top-level/nested **별도 slot namespace** — nested 가 자기 namespace 1글자 처음부터 재사용
- 모든 함수 scope 의 slot0 = `e`, slot1 = `t`, ...
- top-level 과 nested 가 독립적으로 mangle

esbuild 는 *free-var 정확히 분석* 해서 nested 가 outer 의 어떤 식별자를 참조하는지 → 그 외 모든 1글자 가 자유. ZNTC 의 `markScopeSubtree(0)` 같은 모듈 전체 alive 보수 모델 아님.

## 3. R1-a 가설 — precise free-var 분석으로 c2 안전화

c2 의 markAncestorPath 비대 문제를 *정밀 free-var 분석* 으로 해결한다.

### 3.1 가설

- ZNTC transformer 가 각 nested scope 의 free-var (그 scope 가 사용하는 outer 식별자 set) 을 풍부히 수집
- mangler 에 이 정보 전달 → Phase B 가 nested 의 1글자 풀 reuse 시 free-var set 의 식별자만 회피
- 결과: nested 가 outer top-level 의 *unused* 1글자 를 자유롭게 재사용

### 3.2 reference 부재 위험

- esbuild 의 `MinifyRenamer` 는 top-level/nested 별도 slot namespace → free-var 자체 안 보고 namespace 분리
- oxc/rolldown/SWC 모두 동일 패턴
- **R1-a 의 free-var 분석 + 통합 slot pool 모델은 reference 0**
- 새 모델 → 검증 부담 매우 큼

### 3.3 위험 시나리오 (PoC 머지 전 반드시 측정)

- **collision** — free-var 분석 누락 시 silent runtime broken (cross-module symbol resolution 오류). `feedback_minify_semantic_preserving` 절대원칙 위배
- **size 회귀** — c2/M2 가 이미 보인 zod +3.2KB / effect +61KB. R1-a 가 이를 회수해야 PoC 머지 가능
- **transformer 부담** — 풍부한 free-var 수집 = transformer scan 비용 증가

## 4. PoC 단계별 분해

### 4.1 PR-1 (audit, 코드 0)

- ZNTC transformer 의 현재 free-var 수집 audit (`src/semantic/`, `src/transformer/`)
- mangler 가 받는 scope info 의 현재 정밀도 측정
- esbuild reference (`references/esbuild/internal/renamer/renamer.go`) 정독
- R1-a 의 free-var 수집 필요 정밀도 정량

### 4.2 PR-2 (free-var 수집 infra, byte-identical)

- transformer 에 nested scope 의 free-var 수집 추가 (`free_vars: HashSet<SymbolRef>` per nested scope)
- mangler 가 사용 안 하는 inert state (kill-switch flag OFF)
- 측정: byte-identical 검증 (코드 0 변경 동치)

### 4.3 PR-3 (Phase B precise reuse, flag-gated, kill-switch ON)

- Phase B 가 free-var 정보 활용해 nested 1글자 풀 reuse
- `ZNTC_R1A_PRECISE_REUSE` env flag (default OFF)
- 측정 게이트:
  - zod -2.3KB 이상 (c2 의 +3.2KB 회복 + α)
  - effect 회귀 0 (c2 의 +61KB 해소)
  - rxjs 회귀 0
  - **144-lib smoke 합계 corpus 감소** (회수 입증)
  - **runtime MATCH 144/144** (collision-free 입증)

### 4.4 PR-4 (default-on, kill-switch 유지)

- PR-3 게이트 통과 시만 진행
- default ON, kill-switch 유지
- `RFC_MANGLER_SIZE_GAP_CLOSED.md` §7 갱신

## 5. 측정 게이트 (절대 조건)

PR-3 의 측정 결과 기준 머지/abort 결정:

| 항목 | abort 조건 | 머지 조건 |
|---|---|---|
| zod size | +0B 이상 | -2,300B 이상 |
| effect size | +0B 이상 | -0B 이상 |
| rxjs size | +254B 이상 | -0B 이상 |
| 144-lib corpus | +0B 이상 | -0B 이상 (실 회수 입증) |
| runtime MATCH | <144/144 | 144/144 |
| collision assert | fire | 0 |
| transformer wall time | +5% 이상 | <+5% |

**한 항목이라도 abort 조건 만족 시 즉시 revert + 본 RFC 자체 NO-GO 박제로 격하**.

## 6. 실패 시 revert 절차

PR-3 측정 결과 게이트 미달:

1. PR-3 즉시 close (머지 금지)
2. PR-2 의 inert infra 도 revert (dead code 금지, `project_minify_gap_S_series` 의 #3342 cleanup 선례)
3. 본 RFC 갱신:
   - 상태 → `CLOSED · NO-GO` 로 변경
   - §7 추가: 측정 결과 + abort 사유
4. `RFC_MANGLER_SIZE_GAP_CLOSED.md §3` 표 갱신: R1-a 행 추가 (NO-GO)
5. `project_minify_gap_S_series` 메모리 갱신: "R1-a 도 NO-GO 박제 완료 — 재시도 금지" 도장
6. PR-4 자동 skip

## 7. NO-GO 박제 격하 조건 (영구 종결)

PR-3 게이트 미달 시 본 RFC 자체가 영구 종결:
- 향후 같은 R1-a 또는 변형 (free-var 정밀도 더 높임 / scope info 다른 형태 전달 / hybrid 모델) 재시도 절대 금지
- `RFC_MANGLER_SIZE_GAP_CLOSED.md §3` 의 7 NO-GO 경로 + R1-a = **8 NO-GO 경로** 로 격상
- mangler 코어 알고리즘 회수 영역 영구 종결 확정 (해결 가능성 가설 0)

## 8. 결정 가이드 (본 RFC 머지 전 합의 항목)

본 RFC 머지 전 다음 결정:

1. **박제 충돌 의도적 재시도** 동의 여부 — `RFC_MANGLER_SIZE_GAP_CLOSED.md §3` 와 5 메모리의 "재시도 절대 금지" 박제 위배 의도. 사용자 명시 의향 (2026-05-27) 으로 1회 spike 허용
2. **수개월 R&D 투자** 동의 여부 — PR-1 audit + PR-2 infra + PR-3 PoC + PR-4 머지 = 단일 세션 범위 초과. 별도 epic 트랙
3. **게이트 미달 시 영구 종결** 동의 여부 — §7 NO-GO 박제 격하 절차
4. **reference 0 위험** 동의 여부 — esbuild/oxc/rolldown/SWC 모두 미채택 모델 시도. 새 architecture R&D 부담

---

**Refs**:
- `RFC_MANGLER_SIZE_GAP_CLOSED.md` §3 (NO-GO 7 경로)
- `RFC_NESTED_SCOPE_RENAMER.md` (PR #3393/#3395 +174B 실측)
- `project_minify_gap_S_series` §c2 / §M2 단락 (zod +3.2KB / effect +61KB 박제)
- `project_object_key_unquote_win` §2026-05-27 도장 (corpus 0.760x 현재 위치)
- `references/esbuild/internal/renamer/renamer.go` (MinifyRenamer/AssignNestedScopeSlots)
- ZNTC `src/codegen/unified_mangler.zig` (Phase A) / `src/codegen/mangler.zig` (Phase B) / `src/codegen/linker.zig:799-816` (1글자 reserved)
- ZNTC `src/codegen/mangler.zig` `precise_liveness` (#3335 inert infra, R1-a PR-3 재사용 후보)
