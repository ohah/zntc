---
"@zntc/core": patch
---

`--preserve-modules --minify`(ESM/CJS)에서 서로 다른 wrap dep 의 동명 export 가 붕괴하던 것 수정 (#4532 증상1 minify 잔여). preserve-modules 의 minify 를 splitting 과 **동일한 per-chunk mangle + 전역명 브리지 모델로 통합**한다.

```js
// b.js: export function tag(){ return "B"; }
// c.js: export function tag(){ return "C"; }
// a.cjs: module.exports = require("./b.js"); require("./c.js");
// entry: import { tag } from "./b.js"; import { tag as tag2 } from "./c.js"; import "./a.cjs";
//        console.log(tag() + tag2());
// node canonical: "BC"
// 버그(--minify): "BB"  ← 전역명 게이트가 `!minify_identifiers` 로 닫혀 동명 붕괴
```

## 배경

증상1(#4570)이 non-minify 만 고쳤다. minify 는 cross-file 네이밍 게이트(`pm_xchunk_naming`)가 `!minify_identifiers` 로 닫혀 여전히 `BB`. 게이트를 그냥 열면(band-aid) 소비자 함수의 mangled nested 로컬이 전역명(예 aliased import 의 `te`)과 충돌해 shadow → `te is not a function`(silent miscompile, `/code-review max` CONFIRMED). preserve-modules 는 mangle 를 finalize 에서 먼저 하고 전역명은 chunk phase(mangle 이후)에 negotiate 하는데, mangler 가 전역명을 미리 알 방법이 없기 때문.

## 수정 (Approach 3 — splitting 과 메커니즘 통일)

1. **`computeChunkMangling` 을 preserve-modules 에도 오픈**(linker.zig): splitting 처럼 chunk phase(전역명 negotiate **후**)에 per-chunk mangle 을 돌린다. `occupied_names`(= imports_from 의 `crossChunkBindingName` = 전역명 + 별칭)를 예약하므로 mangled nested 로컬이 소비 전역명을 shadow 하지 않는다.
2. **`pm_xchunk_naming` 을 minify 에도 오픈**(bundler.zig, `!minify_identifiers` 제거): 전역명 브리지가 mangled 이름을 파일 경계 너머로 조율한다. provider 는 `export { mangled_local as public }`(ESM)·forwarding read(CJS)로 브리지 → top-level 을 mangle 해도 소비자는 공개명으로 import 한다(공개 API 계약 유지).
3. **래퍼 심볼(`exports_X`/`init_X`/`require_X`)을 preserve-modules mangle 후보에서 제외**(linker.zig `collectUnifiedInput`): preserve-modules 는 `preserveModulesWrapperChunk`(#4528)가 wrapper export/declaration 을 **canonical(미-mangle)** 로 직접 찍는다. mangle 하면 본문(codegen rename)은 `var n={}`·`__export(n,…)` 인데 wrapper export 는 canonical `exports_b` 라 undefined. splitting 은 wrapper 를 rename_table 경유 브리지라 mangle 해도 일관돼 제외하지 않는다.

추가로 `/code-review max` 반영:

- **이중 mangle 제거**(bundler.zig): preserve-modules 는 per-chunk mangle(모든 모듈이 자기 청크)이 전담하므로 finalize 의 전역 mangle 은 중복 — `compute_mangling` 에 `!preserve_modules` 를 걸어 낭비되는 full-graph mangle 을 끈다(computeRenames 는 유지).
- **helper virtual module 래퍼도 제외**(linker.zig `is_helper_module` 브랜치): 수정 3 의 가드가 main synthetic 루프에만 있어, wrapped 헬퍼 모듈이 자기 청크가 되면 래퍼가 mangle 되던 갭을 대칭으로 닫음.

## 결과

- preserve-modules minify 도 이제 **top-level 을 mangle**(rollup+terser 모델과 동일) — 공개 export 명은 브리지로 보존, 내부 로컬만 축약. 부수적 size 이점.
- **ESM-wrap dep 의 동명 export**(a.cjs 가 require 로 wrap 강제) 붕괴·aliased 충돌·reserved default named import·배럴·ns 가 minify 에서 정상.

## 검증

- 새 회귀 스위트 `preserve-modules-minify.test.ts` 38종(esm/cjs × plain/minify): 동명 붕괴 BC, aliased-import 충돌 가드(70 로컬→`te` mangle 강제), reserved default, 배럴, 4-way, cross-file 참조, ns, default 값, CJS require_X 래퍼 — 전부 통과.
- 충돌 repro: 수정 전 `TypeError` → 후 정상.
- zig 전체 test 통과, 통합 스위트 무회귀. splitting 무회귀(모든 변경 preserve_modules 게이트).

## 잔여 (#4532 epic — 이 PR 범위 밖, non-minify 에도 존재하는 별개 근본)

- **비-ESM-wrap 동명 export 붕괴**: 동명 provider 가 CJS-flatten(a.cjs) 을 안 거치고 entry 만 import 하면(즉 ESM-wrap 이 아니면) 전역명이 안 붙어 여전히 붕괴(`T1T2T1`). 전역명이 ESM-wrap owner 로 한정돼 있어(chunk.zig, #4559 의도) 비-wrap owner 는 별도. minify·non-minify 동일.
- **익명 `export default class{}`/`function(){}`** in ESM-wrap 모듈: 선언이 top-level 이 아니라 `__esm` 클로저 안에 assign → `export{X}` 가 미선언 참조(SyntaxError). codegen 문제로 minify·non-minify 동일. 별개 근본.
- 증상4(multi-entry 순환), 배럴 자체 exports CJS 직접 `require("./r.js").X`(live getter).
