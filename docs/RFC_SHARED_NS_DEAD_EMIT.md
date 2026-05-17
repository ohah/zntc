# RFC: Shared-Namespace Dead-Emit Gate (esbuild `StarNameLoc=nil` 1:1)

상태: **Draft (§2/§3/§6 계측 정정 — 2026-05-17)** · 분류: M (XL 아님) · 선행: 없음
관련: `project_shared_ns_dead_emit_lever` · nested-scope-renamer epic NO-GO 후속 차순위 레버

> **⚠️ 계측 정정 (instrumented, RFC 초안 루트커즈 반증)**: 초안 §2/§3/§6 의
> "force_inline / `isNamespaceExportConsumed`(`ts.isExportUsed`) 과대보고가
> 원인, 수정 지점 = `metadata.zig:620-622` force_inline 강화" 는 **계측으로
> 거짓 확정**. effect 399 namespace 사이트 전수 `force_inline=false,
> isNamespaceUsedAsValue=false, isNamespaceExportConsumed=false` — tree-shaker
> 정확, RFC 가 강화하려던 gate 는 이미 올바르게 false (RFC 대로 고치면 효과 0).
>
> **진짜 루트커즈**: 초안이 누락한 4번째 경로 — `shared_namespace.zig:191`
> `if (force_inline or has_shadow)` 의 **`has_shadow` 우항**. `hasNestedBinding`
> (`shared_namespace.zig:25-33`)이 importer 의 nested scope 에 export 명과 같은
> 바인딩(effect 배럴의 `map`/`patch`/`empty`/`head` 등 초범용 nested local)을
> 발견하면 `has_shadow=true` → getter 테이블 **전체** materialize. effect
> dead 141건 중 140건이 이 경로 (force_inline 아님). 27 fully-dead 블록은
> 출력에 `X_ns.member` 접근 0개 → shadow fallback 의 보호 명분(shadow 된 멤버
> 접근을 객체로 보존) 자체가 무의미, 순수 dead weight.
>
> **정정된 수정 지점**: `shared_namespace.zig:191` 의 `has_shadow` 항을
> **access-aware** 로. 단 `inner_map.count()>0` 만으로는 불충분(모든 accessed
> 멤버가 shadow 되면 inner_map 비어도 객체 필요 → silent-broken). 올바른
> 판별 = namespace 심볼이 importer 에서 실 참조(value-escape 또는
> member-access) **0건** 인지 (27 dead = 순수 passthrough 0참조 ↔
> all-shadowed-but-accessed = ≥1 member). `isNamespaceUsedAsValue` +
> `analyzeNamespaceAccess` 멤버 유무의 교집합 `has_shadow AND 실access==0`
> 만 제거. **blanket `has_shadow=false` 절대 금지** (~113 live 블록 보존).
> 효과(effect 27 dead / −16.6%)·M 규모·prior-메모리 미저촉 결론은 유지.
> cross-chunk 는 effect single-chunk 라 미발동(`chunk.zig:1131` early-return)
> 이나 §4 불변식(`ns_cross_chunk_targets` 보존)은 code-split 위해 유지 필수.
> 이하 §2/§3/§6 본문은 초안 원문(반증된 가설) — 본 박스가 정정 권위.

## 1. 문제 (실측 확정 — C 천장 스파이크)

ZNTC 트리셰이킹은 경쟁사 최강(non-minify 144-lib 0.759x). minify 격차의 잔존 레버를 measure-first 로 정찰한 결과, **`import * as X` + re-export 시 emit 되는 shared-namespace getter 테이블이 참조 0 인데도 잔존하는 구조적 dead-emit** 가 핵심으로 확인됨.

ReleaseFast `--minify` 실측 분해 (rolldown 최소 기준):

| lib | ZNTC | rolldown | ns-object 분량 | 그중 완전-dead |
|---|---|---|---|---|
| effect | 160796 | 125426 | 37184 B (번들 23.1%) | **27/42 블록 = 26678 B** |
| zod | 63866 | 56428 | 1765 B (2.8%, 격차 아님) | 0 (genuine value-escape) |
| rxjs/three/lodash-es/date-fns | — | — | **0 B** | 0 |

완전-dead 27블록만 미emit 시뮬: effect 160796 → **134118 B (−16.6%)**, rolldown 격차의 **76% 해소**. **caveat**: effect/@effect/fp-ts 코호트 한정 — corpus-wide 효과는 modest·집중적 (zod/rxjs/three/lodash-es/date-fns = 0). nested-renamer epic 의 "유일 레버" 과대평가 전철을 피하기 위해 **PR-1 자체에 measure-first kill-switch** 를 박는다 (§6).

## 2. 루트커즈 (코드 확정)

`import * as X; export { X };` (배럴 re-export 체인) 에서:

1. `src/bundler/linker/metadata.zig:620-622` — `force_inline = isNamespaceUsedAsValue(...) or (exported_locals.contains(local_name) and isNamespaceExportConsumed(...))`.
2. `force_inline` → `src/bundler/linker/shared_namespace.zig:43-204 registerNamespaceRewrites` 가 `var X={}; $x(X,{a:()=>localA, ...})` getter 테이블 materialize (`shared_namespace.zig:724-740`).
3. getter 클로저 `()=>localA` 가 `localA` 의 `reference_count` 를 올림 → 트리셰이커가 테이블 전체를 live 로 오판. 개별 dead getter 는 `isLocalBindingAlive` (line 704-705) 로 skip 되나, **namespace 자체가 어떤 최종 consumer 에도 참조되지 않는데 re-export 스캐폴딩이 `isNamespaceExportConsumed` 를 통해 keep** 하면 객체 전체가 dead-emit 으로 잔존.
4. cross-chunk 경로 `src/bundler/chunk.zig:1139` 는 metadata 전에 `ensureSharedNsVar` 로 **무조건 pre-materialize** (consumer 가 ns 값을 쓰든 안 쓰든).

esbuild 는 이 지점에 정밀 gate 가 있음 — `references/esbuild/internal/js_parser/js_parser.go:17359-17364, 17419-17458`:

```
if symbol.UseCountEstimate == 0 && (ts.Parse || !moduleScope.ContainsDirectEval) {
    if importItems, ok := importItemsForNamespace[s.NamespaceRef]; ok && len(entries) == 0 {
        s.StarNameLoc = nil   // ← namespace 객체 생성 자체를 skip
    }
}
// entries > 0 이면 star→named import 변환 (NS.x → 직접 심볼, 객체는 유지 가능)
```

ZNTC 는 `isNamespaceUsedAsValue`(값-escape) 만 보고, esbuild 의 **"실 use-count 0 + 멤버접근 0 → 객체 미생성"** gate 가 없다. 정확한 등가 = `force_inline` 결정 + cross-chunk pre-materialize 에 "namespace 가 dead-emit 스캐폴딩 외 실 consumer 가 있는가" 조건을 추가.

## 3. 설계 — materialize gate (esbuild `StarNameLoc=nil` 등가)

새 조건 **C (gate)**: namespace 심볼이 (a) value-escape 0 (`isNamespaceUsedAsValue`==false) **이고** (b) static 멤버접근 0 (`NS.x` 전무) **이고** (c) cross-chunk consumer 없음 (`ns_cross_chunk_targets` 미포함, `linker.zig:1855-1858`) **이면** → `force_inline=false`, ns-object **미생성**.

- (a)(b) 둘 다 0 = esbuild `UseCountEstimate==0 && importItems.entries==0`. 이때 객체는 누구도 안 씀 → 안전 삭제 (심볼 재작성 불필요).
- (b) 만 >0 (static `NS.x` 만) = esbuild `entries>0` → star→named 변환 (`NS.x`→직접심볼). **PR-2 범위** (live-binding/TDZ 위험, 별도).
- (a)>0 (값 전달/`NS[k]`/`Object.keys(NS)`/spread) = 객체 필수 → gate 미발동 (현행 유지). `namespace_access.zig:10-40` 이 이미 .opaque 로 분류.
- (c) cross-chunk: `chunk.zig:1139` 가 metadata 전 실행되므로 gate 는 `ns_cross_chunk_targets` 보존 — code-splitting consumer 가 다른 chunk 면 객체 유지 (silent-broken 방지 최우선 불변식).

### ZNTC ↔ esbuild 매핑

| esbuild | ZNTC |
|---|---|
| `symbol.UseCountEstimate == 0` | namespace 의 실 reference (getter-table self-ref 제외) 0 |
| `importItemsForNamespace.entries == 0` | static `NS.x` 멤버접근 0 (`namespace_access.zig`) |
| `!ContainsDirectEval` | scope `subtree_has_direct_eval`/`with` (mangler 와 동일 가드) |
| `s.StarNameLoc = nil` | `force_inline=false` @ `metadata.zig:620-622` + cross-chunk 보존 @ `chunk.zig:1139` |
| `entries>0` star→named 변환 | PR-2: `NS.x`→직접심볼 재작성 |

## 4. 정확성 불변식 (절대 — 오구현 = silent broken 번들)

1. **cross-chunk consumer 가 있으면 gate 미발동** — `ns_cross_chunk_targets` 포함 모듈은 무조건 materialize 유지 (`chunk.zig:1139` 경로 보존).
2. value-escape(`NS` 값 전달, `NS[k]`, `Object.keys(NS)`, spread, dynamic) 1건이라도 있으면 미발동 — `namespace_access.zig` .opaque 신뢰. eval/with subtree 도 미발동.
3. PR-1 은 **완전-dead (a==0 && b==0 && c==0) 만** — static `NS.x` 재작성(b>0)은 절대 PR-1 에 넣지 않음 (PR-2).
4. `member-augment`/`feedback_minify_semantic_preserving` 절대원칙: gate 가 fire 한 모듈의 런타임 출력은 gate-off 와 **byte 의미 동일** (객체를 아무도 안 쓰므로 삭제가 semantic-preserving).

## 5. `project_export_star_precision_no_roi` 와의 구분 (재시도금지 미저촉)

그 메모리는 *참조되는* namespace 의 request-narrowing/부분생성이 ROI 0(typebox: "namespace 객체는 단일값이라 부분생성 불가, 어떤 사용이든 전 멤버 필요")라는 것. 본 RFC 타깃은 *완전 dead(참조 0)* namespace 객체를 *애초에 안 만드는* 것 — 부분생성이 아니라 "아무도 안 쓰는 객체 미emit", 다른 루트커즈. prior 메모리가 배제하지 않은 영역이며 esbuild `StarNameLoc=nil` 정밀 gate 의 직접 이식이다.

## 6. PR 분할 (각 measure-first 게이트)

1. **PR-1 (M, 회수 ~72%)**: 완전-dead gate (a==0 && b==0 && c==0 → 미materialize). 심볼 재작성 **불필요**. `metadata.zig` force_inline 조건 강화 + `chunk.zig` cross-chunk 보존 + value-escape/eval 가드. **measure-first kill-switch**: 실-fixture(Object.keys 강제 아님, 실제 effect import 패턴) effect 회수 **≥ −15% or 즉시 revert·종결**. 회귀 0 (Debug + ReleaseFast, 전수 smoke outputMatch + 기존 lib size 무회귀). 시뮬 −16.6% 는 상한 — 실측 미달 시 nested-renamer 처럼 종결.
2. **PR-2 (M~L, 잔여 ~28%)**: static-only(`NS.x`)→직접심볼 재작성 (esbuild named-import 변환). live-binding/TDZ/순환import 보존 위험 → 별도 게이트.
3. **PR-3**: /simplify 잔여 + 문서 + 메모리 영속.

각 PR: epic 격리 브랜치 → PR(epic 브랜치 base) → rebase merge, main 직접 금지, /simplify 필수, 라벨/assignee, 한국어. PR-1 kill-switch 미통과 시 epic 브랜치 통째 폐기(main 무영향) — nested-renamer 와 동일 안전 절차.

## 7. 리스크

- **silent-broken (correctness-critical)**: gate 오발동 시 namespace 가 필요한 consumer 가 `undefined` → 런타임 파손 (size 회귀 아님). 완화 = §4 불변식 + cross-chunk 보존 + value-escape/eval 가드 + 전수 smoke outputMatch 게이트 + PR-1 kill-switch.
- **ROI 집중성**: effect/@effect/fp-ts 한정, corpus modest. kill-switch 가 과대평가(nested-renamer net+0.003% 전철) 차단.
- **규모 M**: PR-1 은 gate 추가(심볼 재작성 무) — chunk 재파싱 불필요. 메모리 deferred "rolldown chunk재파싱 XL" 보다 좁음.

## 8. 결론

minify 잔존 레버 중 member-augment(#3359) 이후 처음으로 **측정·코드근거·scoped·prior-메모리 미배제**. esbuild `StarNameLoc=nil` gate 의 직접 이식이며 M 규모. effect-cohort 집중이라 corpus 효과는 modest 하나 ROI-per-effort 가 명확하고, PR-1 의 measure-first kill-switch 가 nested-renamer 식 과대평가를 구조적으로 차단한다.

## 9. 실행 결과 (epic 기록)

- **PR-1 (gate)**: `has_shadow` access-aware 억제. kill-switch **NO-GO** — `analyzeNamespaceAccess` liveness-blind 라 dead 도 member-access=true → effect 0% 회수. 폐기.
- **루트커즈 정정 (직접 빌드파일 diff)**: effect `ZNTC 160,811 vs rolldown 125,417` 격차의 **105%(37KB)가 `var X_ns={};augment(...)` 스캐폴드 43개**. competitor 는 gate 아닌 **`X.member`→직접심볼 전면 재작성**으로 객체 제거. RFC §2~§6 초안(gate/force_inline)은 계측·직접측정으로 반증 — 상단 정정 박스 + 본 절이 권위.
- **PR-2 (rewrite, GO·머지)** #3407: `Linker.nsMemberRewriteSafe()` (mangle-safe) 일 때 `hasNestedBinding` shadow-skip 비활성 → `X.member`→exp.local 재작성. **effect 160,811→127,765 (−20.6%)**, 전수 144-lib build/runtime MATCH 회귀 0·size 증가 0. 안전성=mangler invariant(`collectUnifiedInput` ns target 항상 cross_module reserve, Debug panic 증명). `ZNTC_NO_NS_REWRITE` kill-switch(force-ON 미제공). 비-minify/dev/preserve-modules 는 보수적 shadow-skip 유지.
- **PR-3 (cleanup)**: env-presence flag 중복 boilerplate → `src/env_flag.zig` `Once()` 제너릭 단일화 (transpile fast-path + ns-rewrite kill-switch). byte-identical.
- **순효과**: corpus −0.65% (effect/@effect/fp-ts cohort 집중 — zod/three 등 ns-barrel 없는 lib 불변). member-augment 이후 첫 진짜 size win. RN production minify 는 144-lib smoke 미포함(invariant 상 안전, 실측 외).
- **메타**: bounded *gate*(PR-1·prior NO-GO)만 재시도 금지, *rewrite*(PR-2·GO)는 competitor 실기법으로 유효 — 별개. 근본 규명 결정타 = 내부 추정 아닌 **직접 빌드파일 diff**.
