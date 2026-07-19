---
"@zntc/core": patch
---

`--preserve-modules` 에서 서로 다른 파일이 **같은 로컬명으로 `export default`** 하고 한 소비자가 둘 다 default import 하면 `SyntaxError: Identifier 'foo' has already been declared` 로 파싱 실패하던 것 수정 (#4576).

```js
// m1.js: export default function foo(){ return "D1"; }
// m2.js: export default function foo(){ return "D2"; }
// entry: import a from "./m1.js"; import b from "./m2.js"; console.log(a() + b());
```

방출(esm) 이 `import { default as foo }` 를 두 번 내 `foo` 중복 선언으로 깨졌다.

## 근본

소비자 import 블록(chunks.zig)의 `$N` deconflict 는 **`key == binding`**(export 명 == 로컬명) 분기에서만 했다. default 는 key=`default`, binding=`foo`(익명은 `_default`)라 **`key != binding` 분기**로 가는데 그 분기가 deconflict 를 안 해 로컬명이 여러 dep 에서 중복됐다. #4572(named 동명)와 같은 계열이지만 emit 분기가 다르다.

## 수정

**선언되는 소비자-로컬은 항상 binding** 이므로, 충돌 카운트를 export-명-keyed → **binding-keyed 로 통일**하고 두 분기(`key==binding` 축약 / `key!=binding` alias) 모두에서 `binding$N` deconflict 를 적용한다. deconflict 된 이름은 `consumer_import_local`(#4572) 맵에 기록해 body 참조(effective_target)를 맞춘다. ESM-wrap dep 의 `let X;` forwarding 사이트(#4528)도 같은 binding-keyed 카운트를 공유해 `$N` 이 일치한다.

`export const foo` + `export default function foo` 처럼 두 분기가 섞여 같은 로컬명을 만드는 cross-branch 충돌도 통일 카운트로 해소된다.

## 검증

- 회귀 스위트 `preserve-modules-samename-default.test.ts`: named/익명 default·cross-branch·3-way(esm plain/whitespace/syntax minify) → 각 정확한 출력. cjs 는 중복 로컬 선언이 사라짐을 emit 으로 확인.
- preserve-modules·cross-chunk·splitting·wrapper 통합 전반 + zig 전체 test 무회귀.

## 별개 선행 버그(별도 후속)

- **`--minify-identifiers`**: mangler 가 소비자 default import 의 로컬은 개명하는데 body 참조는 다른 심볼로 취급해 발산(silent). 이 fix 유무와 무관하게 main 도 동일 — mangler 심볼-정체성 문제로 별도.
- **cjs default interop**: `module.exports = foo` provider 를 소비자가 `{ default: foo }` 로 구조분해해 `foo is not a function`. 단일 default 도 실패(중복과 무관). 이 fix 로 중복선언 SyntaxError 는 제거되지만 interop 오류는 별도.
