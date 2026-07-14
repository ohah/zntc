---
"@zntc/core": patch
---

`--preserve-modules` × wrap 된 모듈의 남은 결함 3건 수정 (#4528). 셋 다 빌드 exit 0 · 실행만 실패였다.

## 1. wrap 된 ESM dep 의 named import 가 아예 바인딩되지 않았다

```js
// b.js  (CJS 가 require 하므로 ESM-wrap 됨)
export function tag(){ ... }
// entry.js
import { tag } from "./b.js";   // → ReferenceError: tag is not defined
```

**wrap 종류마다 규칙이 다르다** — 이걸 놓쳤다.

- **CJS**: 본문 **전체**가 `__commonJS` 클로저 안 → 파일 top-level 에 export 명이 없다(래퍼뿐). 그래서 심볼을 import 하면 provider 가 내지도 않는 이름을 가져와 SyntaxError.
- **ESM-wrap**: 클로저에 들어가는 건 **부수효과 문장뿐**이고 `function tag(){}` 같은 **선언은 파일 top-level 에 남는다**. 소비자도 bare 로 참조한다(단일 번들과 동일).

CJS dep 만 심볼 목록을 버리고, ESM-wrap dep 은 래퍼 **와 함께** 심볼도 가져오도록 했다. provider 쪽도 두 군데 전제가 거짓이었다 — "codegen 이 entry 모듈의 `export {}` 를 이미 낸다"(ESM) / "emitCjsEntryExports 가 이미 깐다"(cjs) — wrap 된 모듈은 둘 다 안 한다(`__export(exports_X, …)` 로 들어간다).

## 2. `--minify` 에서 래퍼 이름이 3자 불일치

```js
// b.js (소비자)          // a.js (provider)
import{o}from"./a.js"     export{require_a}
var a = require_a();      // ← 본문은 또 다른 이름
```

`rename_table` 이 **청크별**이라 provider emit 시점과 consumer emit 시점에 같은 심볼이 다른 이름으로 해석됐다. 래퍼 선언은 emitter 가 **직접** 찍어서 codegen 의 rename 대상이 아니다(= 본문은 canonical 을 쓴다) → **canonical 하나로 통일**하면 본문·provider·consumer 3자가 항상 일치한다.

## 3. CJS user entry 가 본문을 실행하지 않았다

wrap 된 CJS 진입점은 아무도 `require_X()` 를 부르지 않아 **본문이 아예 실행되지 않았다**(`console.log` 조차 안 찍힘). 진입점만 직접 호출한다 — dep 는 여전히 lazy 다(eager 호출은 CJS 순환을 죽인다, #4526).

⚠️ preserve-modules 는 **모든 모듈이 자기 `entry_point` 청크**라 청크 종류로는 진입점을 못 가른다 — 모듈의 `is_entry_point` 플래그를 봐야 한다.
