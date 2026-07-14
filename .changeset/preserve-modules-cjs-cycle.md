---
"@zntc/core": patch
---

`--preserve-modules` + `--format=cjs` 에서 **CJS↔CJS 순환**이 로드 시 `TypeError` 로 죽던 것 수정 (#4526).

```js
// a.cjs
const b = require("./b.cjs");
exports.a = function a(){ return "A+" + b.b(); };
// b.cjs
const a = require("./a.cjs");
exports.b = function b(){ return "B"; };
```

node 정본은 `A+B` (require 가 lazy 라 순환 정상 처리). `--format=esm` 도 정상. `--format=cjs` 만 `TypeError: require_a is not a function`.

근본 원인: cjs 소비자가 래퍼 심볼을 **구조분해**했다.

```js
const { require_b } = require("./b.js");   // ← 로드 시점에 값을 **복사**
```

순환에서 b.js 가 **아직 평가 중인** a.js 를 require 하면 `exports.require_a` 가 미할당이라 **undefined 를 박제**한다. ESM 은 live binding 이라 나중에 할당된 값을 보고, node 자신은 `require()` 가 partial exports **객체**를 돌려주고 그걸 참조로 들고 있으므로 무사하다 — 구조분해가 그 지연을 깨뜨린다.

처방: 래퍼 심볼(`require_X` / `init_X`)은 **함수**라 호출 시점에 조회하도록 lazy forwarding 으로 바인딩한다.

```js
const __zntc_w0 = require("./b.js");
const require_b = function() { return __zntc_w0.require_b.apply(this, arguments); };
```

실제 호출은 모듈이 완전히 평가된 뒤에 일어나므로(`entry` → `require_a()` → a 본문 → `require_b()` → …) 그때는 provider 의 `exports.require_X` 가 이미 채워져 있다.
