# RFC: Nested-Scope Renamer Port (esbuild `renamer.go` 1:1)

상태: **Draft** · 분류: XL · 선행: 없음 (mangle_audit 인프라 머지됨, 재사용)
관련: `project_minify_gap_S_series` (RFC #3288 후속, 재시도-금지였던 Option B 의 *안전판*)

## 1. 문제 (실측 확정)

ZNTC 트리셰이킹은 경쟁사 대비 **최강** — 전수조사(144 lib, non-minify): ZNTC win 105 / tie 26 / 큼 13, 총합 **0.759x** (esbuild/rolldown/rspack 최소 대비 24% 작음).

격차는 **100% 미니파이 단계**에서 발생:

| 단계 | ZNTC vs best |
|---|---|
| tree-shake (non-minify) | **0.759x** (압승) |
| minify | 0.888x (리드 까먹음) |

미니파이 압축률(minify/non-minify, 낮을수록 강): **ZNTC 0.547 / esbuild 0.429 / rolldown 0.462 / rspack 0.333**. 43개 lib 에서 "tree-shake 동급이상 → minify 역전".

분해(immer): 전체 격차 ≈ 식별자 mangle. **ZNTC 1-char=240 vs esbuild 958** (ZNTC 가 1자 자리에 2자). effect: avg ident 3.82 vs 2.99.

## 2. 루트커즈 (코드 + 4-레퍼런스 대조 확정)

ZNTC mangler 2-phase:
- **Phase A** (`unified_mangler.zig`): cross-module top-level, 전역 counter+reserved, 빈도순 base54.
- **Phase B** (`mangler.zig`): per-module nested, `external_reserved` 로 Phase A 이름 전파, **flat per-module mangle**.

bare scope-hoist (zod/three/effect/lodash — 현대 dist 지배적) 에서 Phase A internal (zod 86%/three 99%/effect 94%, cross-module ref 없음) 이 **전역 54개 1-char 풀을 선점** → 같은 모듈 nested + 타 모듈 전부 2-char fallback (zod: PhaseB reserved=119, skips_1char=51).

**왜 단순 수정 불가**: Phase B 가 flat per-module mangle — nested scope 에서 1-char 안전 재사용하려면 그 함수가 free-ref 하는 outer 이름과의 충돌 회피에 정밀 scope-tree slot 분석 필요. ZNTC 는 그 인프라 부재 → 순진한 per-module 리셋은 **size 회귀가 아니라 silent 런타임 broken** (cross-module/shadow 오참조), `feedback_minify_semantic_preserving` 절대원칙 저촉. (J-step3b 프로토타입 실측 = effect 0 + audit underflow, revert.)

4-레퍼런스 코드 대조: webpack(Terser per-scope `cname` 리셋)/rspack(SWC 동형+multi-pass compress)/esbuild/rolldown(oxc) **전부 "안정된 단일 scope-tree 위 mangle"**, cross-module phased 카운터 안 들고감. ZNTC 만 phased+reserved (병렬/증분 enabler 의 지름길).

## 3. 레퍼런스 해법 — esbuild `renamer.go` (병렬+증분 유지 *입증*)

`references/esbuild/internal/renamer/renamer.go`:

### 3.1 `AssignNestedScopeSlots` (parse-time, **per-module 병렬**)
재귀 scope-walk. 각 scope 심볼에 `NestedScopeSlot = slot[ns]++` 부여하되 **자식 scope 는 부모의 `slot` 카운트를 복사받아 시작** (`assignNestedScopeSlotsHelper(child, symbols, slot)`):
- **형제 scope 는 같은 slot 번호 재사용** (동시 live 불가 → 같은 minified 이름 안전) = **구성적 그래프 컬러링**.
- 자식은 부모 slot 카운트 *이후*부터 → **부모(closure-captured) 이름과 절대 충돌 안 함** = silent-breakage 원천 차단.
- top-level 멤버는 일시적으로 valid 마킹해 nested slot 안 받음 (hoisted var 보호) 후 복원.
- `UnionMax` 로 형제 간 최대 slot 수 집계.

### 3.2 `AssignNamesByFrequency` (namespace별 빈도순)
slot 을 `count` 내림차순 정렬 → `NumberToMinifiedName(nextName++)`, reserved/keyword/JSX-capital/private-`#` skip. **고빈도 slot 이 1-char**.

### 3.3 phase 분리 (병렬·증분의 핵심)
- nested slot = **parse 시 per-module 병렬** 사전계산 (`NestedScopeSlot`).
- count 누적 = **atomic (병렬-safe)**.
- **top-level slot 할당만 serial** (`AllocateTopLevelSymbolSlots`, 소수) — 명시 주석: "allocate these in serial instead of in parallel".

→ 즉 **"병렬 nested + 얇은 serial top-level"** = 사용자가 요구한 4a/4b 분해의 정확한 레퍼런스 구현. **esbuild 13ms 가 perf 무손실 입증.** 증분 호환: nested slot 은 per-module → 변경 모듈만 그 scope-tree 재-walk.

## 4. ZNTC 포트 설계

| esbuild | ZNTC 포트 |
|---|---|
| `Symbol.SlotNamespace()` `Symbol.NestedScopeSlot` | `Symbol` 에 `slot_namespace: enum` + `nested_scope_slot: ?u32` 추가 |
| `AssignNestedScopeSlots` 재귀 walk | `mangler.zig`/신규 `nested_slots.zig` — parse-time/semantic 후 per-module 재귀 (ZNTC 기존 scope tree + #2956 subtree-liveness 와 정합) |
| `AccumulateSymbolCount` (atomic) | per-module ref count (ZNTC `reference_count`/Reference 재사용) |
| `AllocateTopLevelSymbolSlots` (serial) | 기존 `unified_mangler` Phase A 대체/통합 (top-level serial 유지) |
| `AssignNamesByFrequency` + `NumberToMinifiedName` | ZNTC base54 + 빈도정렬 (기존 Phase 4 logic 재사용, slot 모델로 교체) |

Phase B (현 flat per-module) → **재귀 nested-scope-slot walk 로 전면 교체**. Phase A (top-level serial) 유지·정합.

## 5. 정확성 불변식 (절대원칙)

- 자식 scope slot = 부모 slot 카운트 이후 → closure-captured outer 이름 충돌 **구성적 불가** (esbuild 와 동일 보장). 이게 flat-mangle 이 못 주던 안전성.
- ZNTC `#2956` subtree-liveness 와 1:1 매핑 검증 필수 (선언 scope subtree alive ↔ esbuild slot 상속 동치성).
- `SlotMustNotBeRenamed` (예약어/외부/skip_symbols) 정확 분류 — 오분류 = silent broken.
- `mangle_audit` (cross_module/internal/internal_wrapped, 머지됨) 로 매 PR 회귀 가드.

## 6. PR 분할 (각 measure-first 게이트)

1. **PR-1**: `Symbol` slot 필드 + `AssignNestedScopeSlots` 재귀 walk 구현 (behavior 무변경, flag off, unit test = esbuild fixture 1:1 slot 동치). 회귀 0.
2. **PR-2**: `AssignNamesByFrequency` slot 모델 + unified_mangler Phase A 통합 (flag off). 
3. **PR-3**: flag on, 전체 smoke gate ON/OFF diff — **압축률 0.547→~0.43 도달 + 회귀 0 + 런타임 MATCH 전수** 실측. 미달 시 revert (measure-first 종결).
4. **PR-4**: /simplify + 문서 + 영속.

각 PR `feedback_workflow`: 별도 브랜치 → PR → rebase merge, **main 직접 금지**, /simplify 필수, 라벨/assignee.

## 7. 리스크 / 비용

- **성능: 무손실** (esbuild 13ms 입증 — nested per-module 병렬 + atomic count + thin serial top-level; 증분: 변경모듈 scope-tree만 재-walk). 트릴레마의 벽은 "성능"이 아니라 아래.
- **correctness-critical 대공사**: flat→재귀 slot-walk 전면 교체. 오구현 시 size 회귀 아닌 **silent 런타임 파손**. 완화 = esbuild `renamer.go` 1:1 충실 이식 + esbuild fixture slot 동치 테스트 + mangle_audit + 단계별 flag + 전수 smoke MATCH 게이트.
- 범위 XL (4 PR, 수 세션). measure-first: PR-3 에서 압축률 미회수 시 즉시 종결 (epic 규율).

## 8. 결론

minify 격차의 유일·진짜 레버 = mangler nested-scope-slot 인프라. esbuild `renamer.go` 가 **병렬·증분·perf 무손실로 가능함을 코드로 입증**. ZNTC 의 벽은 트레이드오프가 아니라 **안전한 nested-scope renamer 인프라 부재** — 1:1 이식으로 해소 가능하나 correctness-critical XL. 본 RFC = 그 이식의 설계·PR 분할·measure-first 게이트 정의.
