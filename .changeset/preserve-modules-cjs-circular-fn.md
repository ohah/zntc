---
"@zntc/core": patch
---

`--preserve-modules --format=cjs` 순환 import 에서 **function 선언 export** 가 소비자 로드 중 `undefined` 로 잡혀 `TypeError` 나던 것 수정 (#4532 증상4).

```js
// e1.js: import { b } from "./e2.js"; export function a(){ return "A"; }
// e2.js: import { a } from "./e1.js"; export function b(){}  a();  // ← 로드 중 e1.a() 호출
```

## 근본

cjs 는 `exports.a = a` 를 모듈 본문 **끝**(require 뒤)에 방출한다. 순환에서 e2 가 e1 을 require 하는 시점엔 e1 의 `exports.a = a` 가 아직 실행 전 → e2 의 `require("./e1.js").a` = undefined. ESM 은 function 선언이 hoisting 돼 live-binding 으로 항상 함수(`typeof a === "function"`). esm 출력은 정상이라 **cjs 전용**.

## 수정

unwrapped preserve-modules cjs 모듈의 **named function 선언 export** 를 `exports.<fn> = <local>;` 로 require 블록 **앞**에 hoist(function 은 스코프 상단으로 hoisting 되므로 참조 가능) + bottom 방출에서 제외(중복 방지).

- 판정 `exportBindingIsHoistableFn`: 직접 `.local` 선언 + semantic `decl_flags.is_function`. re-export 는 소스가 자기 것 hoist 하므로 제외. default 는 `module.exports`/`exports.default` 모드 로직과 충돌해 제외.
- 삽입은 `computeRenamesForModules` 후(리네임명 확정), `ns_preamble` insert 앞(위치 shift 방지). `ns_preamble_pos`/insertSlice 선례를 따름.
- bottom 제외는 `emitCjsEntryExports` 에 hoisted-이름 집합 전달(같은 predicate 공유 → 발산 없음).
- live getter(#4532 증상3 서 엣지 다수로 드롭)를 피하고 값 hoist 로 처리.

## 검증

- 회귀 스위트 `preserve-modules-cjs-circular-fn.test.ts` 6종: 다중-entry 순환 function 호출(esm/cjs × plain/minify)·default 병존 named 순환·non-circular(hoist 무해).
- preserve-modules 189·cross-chunk/splitting/wrapper 186 통합 + zig 전체 무회귀.

## `/code-review max` 반영

- **[0]** hoist 게이트가 `output_exports` 를 안 봐 `--output-exports=none`/`default_` 에서도 `exports.fn=fn` 이 새던 것 → `.auto`/`.named` 로 게이트(hoist·skip 양쪽).
- **[1][2]** `exports.X=X` 방출을 `appendCjsExportBinding(live=false, min=false)` 재사용으로 단일화 — 같은-파일 bottom(emitCjsEntryExports, minify 무시 ` = `/`;\n`)과 형식 일치.

## 한계 (별개, 이 fix 범위 밖)

- **소비자 자신의 import 가 TDZ**: 순환 중 paused 모듈의 `const { b } = require(...)` 는 아직 미초기화라, 그 모듈의 함수가 자기 import 를 참조하면 TDZ. 소비자-측 lazy 참조 필요(별개 층).
- **const/let/class export** 는 hoisting 불가·ESM 도 순환서 TDZ 라 대상 아님.
- **default 의 순환 접근** 은 `module.exports` bind-whole + partial 로 별개.
