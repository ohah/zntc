---
"@zntc/core": patch
---

주입된 래퍼 참조(`require_x()`)가 **소비자의 스코프 바인딩**에 가려져 무성 TypeError 가 나던 것 수정 (#4533).

```js
function load(){
  function require_legacy(){ return "SHADOW"; }   // 소비자의 바인딩
  return require("./legacy.cjs").foo();            // → require_legacy().foo() → 가려짐
}
```

`require("./legacy.cjs")` 는 emit 시 그 자리에서 `require_legacy()` 로 재작성되는데, 그 지점 스코프 체인에 동명 바인딩이 있으면 그게 래퍼를 가린다 → `require_legacy(...).foo is not a function`. 빌드 exit 0 · 파싱 통과 · **실행만** 실패.

## 처방 (esbuild/rolldown 방식)

**가리는 사용자 바인딩을 리네임**한다 — 래퍼 이름은 절대 안 건드린다. 래퍼 이름은 cross-chunk 전역명·preserve-modules 공개 export·mangler 등 **여러 서브시스템이 공유**하는 값이라 그걸 바꾸면 파급이 크다(래퍼를 리네임하는 접근은 cross-chunk desync / preserve-modules export 불일치 / mangler 무효화를 연쇄로 낳았다). 소비자의 지역 바인딩은 그 모듈 안에서만 참조되므로 리네임이 **로컬**하다.

- `Linker.resolveWrapperConsumerShadows` — 각 소비자의 `import_records` 로 참조하는 래퍼 이름을 모아, 소비자 스코프(중첩; CJS 소비자는 클로저 안이라 scope 0 포함)에서 동명 바인딩을 찾아 `rename_table` 로 개명(`require_legacy$1`). `findAvailableCandidate` 로 owner/reserved/canonical/기존 중첩바인딩과 안 겹치는 이름 선택.
- `buildMetadataForAst` 에 nested(scope 1+) rename 반영 추가 — module-scope self-rename 루프는 `scope_maps[0]` 만 봤다. **non-minify 전용**: minify 는 mangler(Phase B)가 nested 를 담당하고 scope-aware 라 shadow 를 자연히 피한다.
- 단일 번들 / code-splitting(`computeRenamesForModules`) 양 경로에 배선.

## 곁다리로 닫히는 것

- **#4530**(래퍼 vs 사용자 **top-level** 심볼): main 의 `reserved_globals` 예약이 그대로 담당(이 PR 은 안 건드림).
- **#4536**(asset/disabled 래퍼): 리네임 대상이 래퍼가 아니라 **소비자 바인딩**이라 래퍼에 심볼 테이블이 없어도 커버된다 — `wrapper_name_synthetic` 도 매칭 대상에 포함.

정본 대조: node / esbuild / rspack / **rolldown** 전부 이 방식(소비자 바인딩 리네임). effect/zod/three `--minify` byte-identical(size 0).

## code-review 반영 (2차)

- 개명 후보가 CJS 소비자의 **scope-0(클로저 지역) 바인딩**과도 안 겹치게 `pickConsumerShadowName` 추가(`findAvailableCandidate` 는 scope 1+ 만 봄 → `require_legacy$1` 이 이미 있으면 거기 개명하던 재선언 결함).
- 주입 이름 집합에 런타임 헬퍼 `__toCommonJS`/`__toESM` 포함(ESM-wrap interop `(init_x(), __toCommonJS(exports_x))`).
- **minify 는 pass 전체 skip** — mangler 가 모든 바인딩을 유일명으로 개명해 섀도가 원천 불가(검증됨). non-minify 만 metadata nested 스캔.
- `captureRenamesToPending` 에 nested(scope 1+) rename 의 `declaration_span` 재매칭 추가 — AST 변형(const-materialize) 후에도 소비자 shadow-rename 이 살아남게(방어적: module-scope rename 도 있는 소비자가 변형될 때만 발동).

## code-review 반영 (3차) + 범위

- **[3] splitting**: per-chunk 경로(`computeRenamesForModules`)의 `reserved_globals` 가 wrapper 이름·global_identifiers 를 안 예약해 형제 래퍼(`require_x$1`)와 겹치는 후보를 고르던 것 수정 — collectReservedGlobals 와 동일 예약.
- **[2] incremental carryover**: `captureRenamesToPending` 이 scope 0/nested 동명 시 nested rename 을 scope-0 심볼에 오귀속하던 것 수정(old 심볼이 실제 module-scope 일 때만 그 경로).

⚠️ **범위(#4538 epic 로 분리)**: 아래 **드문 edge** 는 이 PR 범위 밖 — cold 공통 케이스는 유지되고 main 대비 regression 아님.
- 런타임 헬퍼(`__toESM`/`__toCommonJS`, `--minify-whitespace` 의 `$tE`/`$tC`)를 지역 변수로 shadow (사용자가 그렇게 이름 짓는 건 사실상 없음).
- `require.context` 로 도달하는 래퍼.
- HMR/incremental warm 재빌드에서 CJS scope-0 shadow 를 **나중에** 추가할 때 stale reuse (dev-only).

## code-review 반영 (4차, 수렴)

- **[0] eval/`with` 가드**: 소비자 스코프에 direct `eval`/`with` 가 있으면(=`blocksMangling()`) 개명하지 않는다 — 그 안의 동적 조회가 바인딩을 **이름 문자열**로 참조할 수 있어 리네임이 그걸 깬다. zntc mangler 도 같은 이유로 그런 모듈을 skip(#1258), esbuild 도 direct-eval 스코프를 deopt. (⚠️ eval+shadow 동시 케이스의 잔여 shadow 는 근본적으로 해결 불가한 엣지 — esbuild 도 동일하게 둔다.)
- **[1] per-chunk 예약 축소**: 전 모듈 래퍼를 예약하던 것을 **이 청크가 실제 import 하는 래퍼**만으로 좁힘 — 무관한 다른 청크의 동명 사용자 심볼이 불필요하게 리네임돼 content-hash 파일명이 흔들리던 것 방지.
- **[perf]** metadata nested 스캔을 `has_nonminify_nested_shadow`(scope 1+ 개명이 실제로 있을 때만 true)로 게이트 — 섀도 없는 절대다수 빌드에서 O(전 모듈 nested 바인딩) 스캔 제거.

## code-review 반영 (5차, 수렴)

- **[2] splitting 선언측 #4530**: per-chunk reserved 를 참조측(import 하는 래퍼)뿐 아니라 **선언측**(이 청크에 놓이는 wrapped 모듈 자신의 래퍼)까지 예약 — 래퍼 선언(`var require_X=__commonJS`)과 동명인 co-chunk 사용자 top-level 이 중복 선언되던 것(main 의 splitting #4530 갭) 수정.
- **[perf]** metadata nested 스캔 게이트를 전역 bool → **개명된 모듈 index 집합**으로 — 스캔이 영향 모듈에만 비례.
- **[cleanup]** 래퍼 예약을 `reserveWrapperNames(module)` 단일 헬퍼로(collectReservedGlobals + per-chunk 공유). 코드 주석의 외부 출처 표기 제거(컨벤션).

⚠️ **알려진 HMR perf**(#4538): nested shadow-rename 이 있으면 HMR rename-reuse 스냅샷이 폐기돼 warm 재빌드가 full 재계산으로 떨어진다(정확성 유지, shadow 있는 프로젝트만). symbolLocalName 이 nested SymbolID 를 못 역매핑하기 때문 — reuse 를 nested rename 까지 확장하는 건 #4538.

## code-review 반영 (6차, 수렴 — correctness 잔여 0)
- **[0] --minify-whitespace 헬퍼명**: interop 헬퍼 shadow 매칭에 축약명(`$tE`/`$tC`, NAMES.TOESM_MIN/TOCOMMONJS_MIN)도 추가 — emit 은 `--minify-whitespace` 에서 축약명을 쓰는데 full 이름만 매칭해 그 조합에서만 nested 헬퍼 shadow 를 놓치던 것 수정. names 배열↔reserveWrapperNames 동기화 주석 추가.
