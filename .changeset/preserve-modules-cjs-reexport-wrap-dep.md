---
"@zntc/core": patch
---

`--preserve-modules`(CJS/ESM)에서 **소비자가 re-export 배럴 경유로 ESM-wrap dep 을 import** 하면 `undefined` 를 잡아 `TypeError: X is not a function` 나던 것 수정 (#4532 증상3).

```js
// b.js:  export const CONST = 42; export function fn(){ return "F"; }
// a.cjs: module.exports = require("./b.js");   // b 를 ESM-wrap 강제
// r.js:  export { CONST, fn } from "./b.js";   // re-export 배럴
// entry: import { CONST, fn } from "./r.js"; import "./a.cjs"; console.log(CONST + "|" + fn());
// 버그(CJS/minify): TypeError: fn is not a function
```

## 근본 원인

ESM 소비자가 배럴 경유로 import 하면 re-export 체인이 wrap dep(b.js)로 직접 해석돼, 소비자 preamble 이 forwarding 썽크(`let X; const init_X = ...`)의 `init_X()` 를 호출해야 X 가 채워진다("소비자는 심볼을 쓰기 전 init_X() 를 부른다"는 계약). 그런데 init 주입 게이트가 **직접 import 대상**(`canonical_m_opt` = 배럴, non-wrap)만 봐서 막혀 `init_X()` 를 안 깔았다 → 소비자가 undefined X 를 참조.

## 수정

소비자 init 주입에서, 직접 대상이 non-wrap 이어도 **`resolved.canonical`(re-export 체인 끝)이 ESM-wrap 이면 그 wrap dep 의 `init_X()` 를 소비자 preamble 에 주입**한다. `esm_init_set` 로 중복 방지, tree-shake 가드 유지.

`/code-review max` 반영:
- **preserve-modules 한정**: 각 모듈이 별도 파일이라 forwarding 썽크(init_X)가 소비자 파일에 로컬 정의된다. splitting 은 init_X 가 cross-chunk 라 이 청크서 undefined 일 수 있어(그쪽은 cross-chunk 네이밍이 별도 처리) 제외.

## 검증

- CJS/ESM × plain/minify **전부** `42|F` (수정 전 CJS/minify 는 `TypeError`).
- splitting(비-preserve-modules)은 게이트로 미적용 — 자체 경로로 정상(`42|F`), 무회귀.
- 회귀 가드: `preserve-modules-cjs.test.ts` 에 증상3 실행 가드(node 실제 실행).
- zig 전체 test + 통합 스위트 무회귀.

## 잔여 (#4532 epic)

- 배럴 **자체** exports 를 CJS 로 직접 `require("./r.js").X` 하는 경로는 별도(live getter 필요 — `__export`/minify 이름·default·wrapped 포맷·accessor 시맨틱 엣지 다수라 별도 설계). 증상 1(동명 붕괴 `BB`) CJS, 증상 4(순환) 도 별개 근본. 후속.
