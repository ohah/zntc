---
"@zntc/core": patch
---

`--splitting` 에서 raw `require("./x.cjs")` 한 CJS 가 common chunk 에 안착하면 그 `require_X` 썽크가 cross-chunk 미노출돼 `ReferenceError` 나던 버그 수정 (#4541).

## 증상
raw `require("./x.cjs")` 로 다른 청크의 CJS 를 참조하면, 소비자 청크는 `import "./chunk"`(side-effect)만 하고 `require_X()` 를 **import 없이** 참조 → provider 청크에만 있는 `require_X` = free variable → `ReferenceError: require_X is not defined`. 빌드 exit 0 · 파싱 통과 · 실행만 실패.

## 루트커즈
`computeCrossChunkLinks`(chunk.zig)는 cross-chunk 심볼을 **`import_bindings` 순회**로만 등록한다. raw `require()` 는 ImportBinding 이 없어(`kind=.require`) `require_X` 가 `exports_to`/`imports_from` 에 안 들어간다(chunk-level 의존 edge=side-effect import 만 생성). `import` 경로(#4494/#4522)는 provider 가 interop 값을 materialize+export 하지만, raw-require 는 그 경로를 안 탄다. wrapper 심볼(`require_X`, scope_id=.none)은 rename 풀에도 없어 심볼 기계가 구조적으로 못 본다.

## 수정
esbuild/rolldown 동형 — provider 가 썽크를 **export**, 소비자가 **import** 후 `require_X()`. raw `require` 는 **lazy**(호출 시점 평가)라 import-path 의 eager materialize(`default$X=require_X()`)를 재사용하지 않고 썽크 자체를 넘긴다.
- `Chunk.wrapper_cross_exports`/`wrapper_cross_imports` 필드 추가 — import-path 의 exports_to/imports_from(export명 키) 기계와 분리(래퍼는 export명이 없음).
- `computeCrossChunkLinks` 에 raw-require 루프: `kind==.require` + CJS 타겟 + 다른 청크면 provider 에 export 표시·소비자에 import 표시.
- provider emit: `export { <로컬> as require_X }`(esm) / `exports.require_X = <로컬>`(cjs). ⚠️ `--minify` 는 provider 본문 선언을 mangle(`r`)하나 소비자는 canonical `require_X` 로 import·호출 → **로컬(mangled)→공개(canonical) aliasing** 으로 3자 일치.
- 소비자 emit: `import { require_X }`(esm, live binding) / cjs 는 **lazy forwarding**(`require("...");` side-effect + `const require_X = function(){ return require("...").require_X.apply(this,arguments); }`) — `const{require_X}=require(...)` 구조분해는 CJS↔CJS cross-chunk 순환에서 로드 시점 스냅샷(undefined 박제) 위험이라 호출 시점 조회로 지연 복원(#4526 계열).
- `buildRequireRewrites` 는 `require_X()` 그대로(변경 불요).

## 범위
esm·cjs 포맷. **preserve-modules 는 #4524 가 자체 wrapper 기계로 담당**하므로 제외(게이트). **iife/umd/amd(reg_split)는 registry 모델이라 후속.**

검증: zig 6227/6227 · split-cjs-cross-chunk #4541 가드 esm/cjs × plain/minify 4종(node 실행) · 인접 splitting/preserve-modules 152 pass · effect/zod/three byte-identical.

Closes #4541

## code-review 반영
- **[r0] cjs 순환 lazy forwarding**: cjs 소비자가 `const{require_X}=require(...)` 로 로드 시점 구조분해하면 CJS↔CJS cross-chunk 순환에서 provider 의 `exports.require_X` 미할당 시점을 스냅샷 → TypeError(#4526 계열). require_X 는 함수라 `const require_X = function(){ return require("...").require_X.apply(this,arguments); }` **호출 시점 조회**로 지연 복원. esm 은 live binding 이라 named import 유지. 순환 가드 추가.
- **[r1] reset 멱등**: `computeCrossChunkLinks` reset 루프에 새 `wrapper_cross_exports`/`wrapper_cross_imports` clear 추가(재실행/HMR re-link 시 stale export 방지).
