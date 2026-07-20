---
"@zntc/core": patch
---

`--preserve-modules --format=cjs` 에서 **재할당되는 export 바인딩**(`export let A = 0; A = 1`)의 live-binding 을 rollup parity 로 수정 (#4587 target a).

```js
// a.mjs  export let A = 'init'; A = 'vA'; console.log(getB())
// b.mjs  import { A } from './a.mjs'; export function getB(){ return A + B }
// 수정 전: undefinedvB   /  수정 후: vAvB
```

## 근본

cjs 가 export 바인딩을 로컬 `var A` + 모듈 끝 `exports.A = A`(스냅샷) 으로 낮춰, 소비자는 `const {A}=require()` 로 import 시점 스냅샷, provider 는 끝에서 한 번만 반영 → 순환/재할당에서 `undefined` 를 박제한다(ESM 은 live binding). 격리 실험으로 **양쪽 다 라이브여야** 정답이 나옴을 확인.

## 수정 (rollup parity)

재할당 바인딩(`write_count > 0` · `let`/`var` · 비 const/class/function · identity export · 단순 선언)을 **`exports.A` 저장소**로 낮춘다:
- provider: 선언 `let A = 0` → `exports.A = 0`, 읽기/쓰기/compound/update/shorthand 를 `exports.A` 로 rewrite(codegen renames 재사용), 모듈 끝 `exports.A = A` skip.
- consumer: 재할당 심볼은 `const ns = require(...); ns.A`(라이브 접근), 비재할당은 현행 구조분해 유지.

`const`/`class`/`function` 은 손대지 않는다 — 각각 현행·#4584 hoist 를 유지해 TDZ·const 보호·mangle·자기참조 사이드 이펙트를 회피(rollup 도 이 층은 exports-as-storage 를 안 한다).

## 스코프 밖(문서화된 한계)

`const`/`class` 의 순환-중-읽기(rollup 도 실패), aliased export(`export { A as B }`), destructuring export, re-export 체인 라이브 전파는 이번 범위 밖 — 전부 현행 동작 유지(무크래시).
