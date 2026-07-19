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

**선언되는 소비자-로컬은 항상 binding** 이므로, esbuild/rollup 리네이머처럼 **소비자 청크의 "이미 쓰인 로컬명" 집합(`used_locals`)으로 유일 이름을 발급**한다(`mintConsumerLocal`): 비었으면 binding 그대로, 이미 쓰였으면 `binding$N`(N=2,3,… 중 `used_locals`·다른 binding 의 자연명 집합에 없는 첫 이름). 두 emit 분기(`key==binding` 축약 / `key!=binding` alias)와 ESM-wrap dep 의 `let X;` forwarding 사이트(#4528)가 **같은 `used_locals` 를 공유**한다. deconflict 된 이름은 `consumer_import_local`(#4572) 맵에 기록해 body 참조(effective_target)를 맞춘다.

핵심은 **per-binding 카운터가 아니라 집합 기반 유일성**이다 — 카운터는 한 그룹의 `foo$2` 가 다른 심볼의 자연명 `foo$2`(또는 사용자 심볼)와 충돌할 수 있다(아래 검증 [0]). 이름이 고정된 심볼(전역명 `has_global`·lazy)은 pre-pass 로 `used_locals` 에 먼저 예약해, 동명 plain 로컬이 그 이름과 충돌하면 순서와 무관하게 deconflict 된다(아래 [1]). `export const foo` + `export default function foo` 같은 cross-branch 충돌도 같은 집합으로 해소된다.

## 검증

- 회귀 스위트 `preserve-modules-samename-default.test.ts`: named/익명 default·cross-branch·3-way + **[0]** dedup 이름이 자연 `foo$2` 심볼과 충돌 회피(→`foo$3`)·**[1]** 전역명 고정 default + plain 동명(import 순서 무관 `PW`) — esm plain/whitespace/syntax minify. cjs 는 중복 로컬 선언이 없고 deconflict 됨을 emit 으로 확인.
- preserve-modules 160·cross-chunk/splitting/wrapper 186 통합 + zig 전체 test 무회귀.

## `/code-review max` 반영

max 리뷰가 초기 커밋(per-binding 카운터)에서 두 correctness 회귀를 짚어 집합 기반(`used_locals`)으로 재설계했다:
- **[0]** dedup `binding$N` 이 다른 binding 의 자연 `$N` 명과 충돌(재현) → `used_locals`+자연명 집합으로 유일성 판정.
- **[1]** `!has_global` 게이트가 전역명 default 를 dedup 에서 제외해 순서-의존 중복(재현) → 고정명 pre-pass 예약.
- **[2]** 중복 alias 분기 → `key != local` 단일 분기로 병합. **[3]** cjs 테스트 vacuous → positive 단언 추가.

## 별개 선행 버그(별도 후속)

- **`--minify-identifiers`**: mangler 가 소비자 default import 의 로컬은 개명하는데 body 참조는 다른 심볼로 취급해 발산(silent). 이 fix 유무와 무관하게 main 도 동일 — mangler 심볼-정체성 문제로 별도.
- **cjs default interop**: `module.exports = foo` provider 를 소비자가 `{ default: foo }` 로 구조분해해 `foo is not a function`. 단일 default 도 실패(중복과 무관). 이 fix 로 중복선언 SyntaxError 는 제거되지만 interop 오류는 별도.
