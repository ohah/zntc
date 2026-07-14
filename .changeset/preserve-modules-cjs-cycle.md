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
require("./b.js");   // side-effect: 실행/등록 순서 보장
const require_b = function() { return require("./b.js").require_b.apply(this, arguments); };
```

실제 호출은 모듈이 완전히 평가된 뒤에 일어나므로(`entry` → `require_a()` → a 본문 → `require_b()` → …) 그때는 provider 의 `exports.require_X` 가 이미 채워져 있다.

⚠️ **holder 변수(`const __zntc_w0 = require(...)`)를 두면 안 된다.** 우리가 이름을 지어 top-level 에 깔면 그 이름은 deconflict 를 안 거쳐서 사용자 코드의 동명 top-level 심볼과 **중복 선언**(`SyntaxError: Identifier '__zntc_w0' has already been declared`)이 난다. `require()` 는 node 가 memoize 하므로 forwarding 안에서 다시 불러도 싸다 — holder 자체가 불필요하다.

추가(코드리뷰): **`exports_X` 도 lazy 여야 한다.** 첫 수정은 함수형 래퍼(`require_X`/`init_X`)만 lazy 로 만들고 `exports_X`(ESM-wrap dep 의 exports 객체)는 eager 복사로 남겼다. 그러면 순환에서 dep 이 **아직 평가 중**일 때 provider 의 `exports.exports_X = …` 가 아직 안 깔려 **undefined 를 박제**하고, 나중에 `__toCommonJS(undefined)` → `TypeError: Cannot convert undefined or null to object` 로 죽는다 — **#4526 이 고치려던 바로 그 결함이 절반만 고쳐진** 것이다.

`exports_X` 는 객체라 forwarding 으로 감쌀 수 없지만, 소비자의 사용처가 **항상** `(init_X(), __toCommonJS(exports_X))` — `init_X()` 가 먼저 평가되는 순차식이다. 그래서 `let` 으로 선언하고 **init forwarding 안에서 갱신**한다.
