---
"@zntc/core": patch
---

생성된 **래퍼 심볼**이 사용자 top-level 심볼과 deconflict 되지 않아 **파싱 불가** 산출물이 나오던 것 수정 (#4530).

```js
// legacy.cjs
module.exports = { foo(){ return "FOO"; } };
// entry.js
function require_legacy(){ return "USER"; }   // ← 사용자 심볼
import d from "./legacy.cjs";
```

방출:

```js
var require_legacy = __commonJS({ ... });     // ← emitter 가 찍은 래퍼
function require_legacy(){ return "USER"; }   // ← 사용자 코드
// → SyntaxError: Identifier 'require_legacy' has already been declared
```

**단일 번들에서도** 재현된다 — 번들 스코프에 모든 모듈의 top-level 이 호이스팅되기 때문이다.

근본 원인: `registerWrapperSymbols` 의 deconflict 풀이 **래퍼 이름끼리만** 봤다. #4475 는 basename 충돌(`a/logo.png` vs `b/logo.png` 가 둘 다 `require_logo`)만 다뤘고, **사용자 코드의 top-level 심볼과는 대조하지 않았다.** CJS 의 `require_X` 뿐 아니라 ESM-wrap 의 `init_X` / `exports_X` 도 같은 위험이 있었다.

처방: 래퍼 이름을 짓기 전에 **모든 모듈의 top-level 심볼 이름을 같은 풀에 seed** 한다 → 충돌 시 `require_legacy$2` 로 갈린다.

size 영향 0 — effect/zod/three `--minify` 산출물이 **byte-identical**(충돌이 없으면 이름이 그대로).
