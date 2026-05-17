# RFC: bundle-context `export const` 선언 병합 (declaration coalescing 사각)

상태: **Draft (instrumented 루트커즈 확정)** · 분류: M · 선행: 없음
관련: `project_decl_coalescing_lever` · shared-ns epic(#3399) 후속 corpus-wide 레버

## 1. 문제 (직접 빌드파일 diff + instrumented 확정)

ZNTC 의 인접 동종 선언 병합(`let a=1;let b=2`→`let a=1,b=2`)은 **이미 구현·작동 중** (`src/transformer/minify.zig` `mergeDecls`/`mergeAdjacentDecls`/`tryMergeWithPrev`, `emitter.zig` 가 `!dev_mode` 시 호출). 모듈내 인접쌍 1278 중 **1267 병합 성공**.

그러나 effect `--minify` 번들: `;let x=` 분리 **841건** vs rolldown 68 (effect ZNTC 127,845 vs rolldown 125,417, gap 2,428B 의 주성분). 직접파일 diff 로 발견 → instrumented 로 사유 규명.

**계측 결과 (per-reason 카운트, 가설 전부 검증/반증):**
- `kind_mismatch=0`, `cap=0`(MAX_DECLS_PER_MERGE 미저촉), `bounds=0` → cap/kind/구조한계 가설 **전부 반증**.
- 지배 사유 = `cur_not_vardecl`, 거부쌍 prev-tag 분포 단일최대 **`.export_named_declaration=241`**.
- 미병합 841 의 정체: effect 소스가 `export const identity=a=>a; export const constant=v=>()=>v; ...` (effect `dist/esm/Function.js` 역추적 정확 일치). bare scope-hoist(103 모듈 전부 `wrap_kind=.none`)에서 codegen 이 `export ` 를 떼고 `let X=a=>a;` 로 출력하나 **AST tag 는 `.export_named_declaration` 유지**.

## 2. 루트커즈 (코드 확정)

- `src/codegen/modules.zig:300-315 emitExportNamed`: bundle context(`lm.is_bundle_context and !x.decl.isNone()`)에서 `export ` 키워드 생략, 내부 declaration 만 emit → 출력은 `let X=...` 이지만 **노드 tag 는 `.export_named_declaration`**, `variable_declaration` 은 child.
- `src/transformer/minify.zig:2099,2119 tryMergeWithPrev`: `cur.tag != .variable_declaration` / `prev.tag != .variable_declaration` 가드로 `.export_named_declaration` 을 (a) 병합 후보에서 원천 제외, (b) 양옆 plain vardecl 의 인접성까지 절단. effect 처럼 거의 모든 top-level 이 `export const` 인 라이브러리에서 mergeDecls 사실상 무력화.
- 보조 (D): bare scope-hoist 는 per-module **string concat** (`emitter.zig:651,805,809` — `:805` string-merge 는 `wrap_kind==.cjs`+`var ` 한정) → 통합 AST 부재로 cross-module 경계 인접분은 본 RFC 범위 밖(별도).

## 3. 설계 — bundle-context export-wrapper 를 병합 대상에 포함

bundle context 에서 `export const X=...` 는 의미상 `let X=...` (codegen 이 이미 그렇게 출력). AST wrapper tag 만 병합을 막음. 두 접근(택일은 PR-1 measure-first 로 결정):

- **A. mergeAdjacentDecls 인지 확장**: `tryMergeWithPrev` 가 `.export_named_declaration` 중 *bundle-context 에서 bare decl 로 emit 되는 것*(child 가 `variable_declaration`, specifier-only/`source` 없음)을 "내부 vardecl" 로 간주해 declarator 병합. 위험: cur→empty_statement idempotency 치환 ↔ export wrapper 의 linker export-rename metadata 충돌 검증 필요.
- **B. linker unwrap**: scope-hoist 단계에서 bundle-context `export const` wrapper 를 plain `variable_declaration` 으로 unwrap(export 매핑은 linker metadata 가 별도 보유) 후 기존 mergeDecls 가 자연히 처리. 더 깨끗하나 unwrap 시점·export 이름 해석 경로 영향범위 선검증.

esbuild/terser 도 bundle 후 top-level 선언을 단일 scope 로 보고 `join_vars`/stmt-merge — wrapper tag 구분 없음. ZNTC 의 사각은 export-wrapper AST 보존이 원인.

## 4. 정확성 불변식 (correctness-critical)

1. export wrapper 는 linker 의 **export 이름 해석/rename map** 과 연결. 병합/unwrap 이 export binding 추적을 깨면 안 됨 (silent-broken). `export const` 다용 lib 전수 cross-check (effect/zod/typebox/lodash-es).
2. 병합은 *동일 kind* + *진짜 인접*(중간 비-선언/side-effect statement 없음) + 동일 scope 만 — 기존 tryMergeWithPrev 제약 유지.
3. for-head/directive prologue/label/`var` 호이스팅/TDZ: 기존 가드 보존. export-wrapper 인지 확장이 이 가드를 우회하지 않을 것.
4. specifier re-export(`export { a } from`)·`export default`·`export *` 는 대상 아님 (child 가 단순 variable_declaration 인 local `export const/let/var` 만).

## 5. PR 분할 (measure-first 게이트)

1. **PR-1 (M)**: 접근 A 또는 B 중 measure-first 유리한 쪽. env flag(`src/env_flag.zig` `Once()` 재사용, default off → byte-identical). **kill-switch**: 전수 smoke `--minify` OFF vs ON — (a) effect 등 size 감소 실측, (b) **build/runtime outputMatch 회귀 0** (export-rename 파손 = silent-broken 1순위 가드), (c) size 증가 lib 0. 미회수/회귀 시 즉시 종결. 회귀 0 Debug+ReleaseFast.
2. **PR-2 (옵션)**: 효과 실측 후 cross-module 경계분(보조 D, string-concat) 가치 판단 — 통합 AST 부재라 별개 난도, deferred 가능.
3. **PR-3**: /simplify 잔여 + 문서 + 메모리 영속.

각 PR: epic 격리 브랜치 → PR(epic base) → rebase. main 직접 금지. /simplify 필수. kill-switch 미통과 시 epic 통째 폐기(main 무영향) — shared-ns/nested-renamer 와 동일 안전 절차.

## 6. 리스크 / 효과

- **silent-broken (correctness-critical)**: export-wrapper ↔ linker rename 연결 파손 시 export 값 오참조. 완화 = §4 불변식 + 전수 smoke outputMatch kill-switch + flag 단계.
- **효과 상한 미검증**: 모듈내 1267쌍은 이미 병합 중. 미병합 841 이 전부 회수될지·cross-module 경계분 제외 후 실 byte 절감은 **PR-1 시제품 실측 필수** (S-series 교훈: size 단정 금지). 단 corpus-wide 보편(모든 `export const` 다용 lib) — ns-object(effect-cohort)보다 광범위 가능성.
- **규모 M**: AST wrapper 인지 확장 또는 linker unwrap, chunk 재파싱 불필요. 구조 본질 제약 아님(계측 확정).

## 7. 결론

declaration-coalescing 은 이미 구현됐고 모듈내는 정상 작동 — 사각은 **bundle-context `export const` 가 `.export_named_declaration` AST tag 로 남아 기존 merge 가드에서 제외**되는 것. 직접 빌드파일 diff 가 레버를 찾고 instrumented 가 "미구현"이 아닌 진짜 루트커즈를 확정(틀린 RFC 회피 — shared-ns 와 동일 규율). bounded M, corpus-wide 잠재. correctness-sensitive(linker export-rename) 라 PR-1 measure-first kill-switch(outputMatch 회귀 0)가 핵심 안전판.
