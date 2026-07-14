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

추가(코드리뷰): 첫 수정이 **회귀 4건**을 만들었다.

- **`module.exports = require_X()` 가 exports 객체를 교체**해, 바로 위에서 깐 `exports.require_X` 를 지웠다 → 이 entry 를 import 하는 다른 파일의 forwarding 썽크가 `undefined.apply` 로 죽는다. 교체 뒤 **재부착**.
- **`pm_entry_call` 이 `.cjs` 만 봐서** ESM-wrap user entry 는 여전히 본문 미실행이었다(같은 결함의 절반). `isWrapped()` 로 넓혔다.
- **cjs 의 `exports.X = X` 는 값 스냅샷**인데 ESM-wrap 모듈의 `const`/`class` 는 `__esm` 클로저(=`init_X()`) 안에서 **늦게 대입**된다 → 파일 top-level 스냅샷은 **undefined**(함수 선언만 hoisting 으로 우연히 살아남아 버그가 가려졌다). provider 는 **getter** 로 노출, 소비자는 **init 시점 갱신**. ⚠️ 선-init 은 답이 아니다 — ESM-wrap 끼리 순환하면 아직 미평가인 상대의 `init_Y`(undefined)를 부른다.
- **회귀 가드가 무력했다** — `buildPm` 에 `minify` 파라미터를 넣는 편집이 조용히 실패해 `--minify` 테스트가 minify 없이 돌고 있었다. 이제 esm/cjs × plain/minify 매트릭스를 실제로 돈다.
