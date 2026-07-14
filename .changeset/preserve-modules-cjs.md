---
"@zntc/core": patch
---

`--preserve-modules` × CJS 가 통째로 깨지던 것 수정 (#4524).

```js
// legacy.cjs
module.exports = { foo(){ return "FOO"; }, bar: 42 };

// entry.js
import d, { foo } from "./legacy.cjs";   // ReferenceError: require_legacy is not defined
const m = await import("./legacy.cjs");  // keys: []  (빈 namespace)
```

근본 원인: **CJS 는 정적 export 가 없어 파일 경계를 넘을 수단이 `require_X` 썽크뿐인데**, preserve-modules 가 그걸 export 하지 않았다. 소비자는 그 썽크를 **렉시컬 참조**했는데 그건 다른 파일의 지역변수다. 즉 preserve-modules 는 CJS 상호작용 **배선 자체가 없었다** — 정적 import 조차 못 썼다.

처방(rolldown 동형): CJS 모듈 파일이 썽크를 export 하고(`export { require_X }`) 소비자가 import 한다. interop 은 소비자가 자기 preamble(`var d = require_X()`)로 이미 하고 있으므로 이름만 건너오면 그대로 동작한다.

동적 import 는 소비자가 `.then((m) => __toESM(m.default))` 로 namespace 를 합성한다 — provider 의 `default` 는 **raw `module.exports`** 여야 하므로(방출 파일을 단독 import 했을 때의 node CJS↔ESM 계약) namespace 를 실을 수 없기 때문이다. splitting(#4522)이 provider 에 namespace 를 싣는 것과 대비된다.

함께 수정: 청크 런타임 헬퍼 주입 게이트가 `needs_cjs_runtime or needs_esm_wrap_runtime` 이라 **`__toESM` 만 필요한 청크를 통째로 건너뛰었다**. preserve-modules 의 소비자는 CJS 도 ESM-wrap 도 없는 순수 ESM 파일이라 `ReferenceError: __toESM is not defined` 가 났다.
