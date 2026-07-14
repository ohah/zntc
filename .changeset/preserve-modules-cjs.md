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

**루트커즈**: wrap 된 모듈(CJS `__commonJS` / ESM `__esm`)은 본문이 클로저 안이라 파일 top-level 에 남는 게 **래퍼 심볼뿐**이다 — CJS 는 `require_X`, ESM-wrap 은 `init_X` / `exports_X`. preserve-modules 가 그걸 export 하지 않아 소비자가 **다른 파일의 지역변수**를 렉시컬 참조했다.

처방: wrap 된 모듈 파일이 래퍼 심볼을 export 하고 소비자가 import 한다. 실제 interop 은 소비자가 자기 preamble(`var d = require_X()` / `(init_b(), __toCommonJS(exports_b))`)로 이미 하고 있으므로 **이름만 건너오면** 그대로 동작한다.

동적 import 는 소비자가 `.then((m) => __toESM(m.default))` 로 namespace 를 합성한다 — provider 의 `default` 는 **raw `module.exports`** 여야 하므로(방출 파일을 단독 import 했을 때의 node CJS↔ESM 계약) namespace 를 실을 수 없기 때문이다. splitting(#4522)이 provider 에 namespace 를 싣는 것과 대비된다.

함께 수정: 청크 런타임 헬퍼 주입 게이트가 `needs_cjs_runtime or needs_esm_wrap_runtime` 이라 **`__toESM` 만 필요한 청크를 통째로 건너뛰었다**. preserve-modules 의 소비자는 CJS 도 ESM-wrap 도 없는 순수 ESM 파일이라 `ReferenceError: __toESM is not defined` 가 났다.

추가: provider(export emit)에만 `format == .esm` 조건이 있어 **`--format=cjs` 에서 어긋났다** — 소비자는 `const { require_X } = require("./x.js")` 를 내는데 provider 는 아무것도 안 깔아 `require_X is not a function`. 두 곳이 `preserveModulesCjsThunkChunk` 단일 술어를 보게 하고, cjs 형식은 `exports.require_X = require_X` 로 깐다.

추가(코드리뷰): 첫 수정은 `require_X` **절반만** 배선했고 회귀도 하나 만들었다.

- **CJS 가 ESM 형제를 `require()`** 하면 여전히 깨졌다 — 소비자가 `init_b`/`exports_b`/`__toCommonJS` 를 렉시컬 참조. 가장 흔한 레거시 interop 모양이다. 래퍼 심볼 전반(ESM-wrap 포함)으로 일반화했다.
- **`export default require_X();` 로 래퍼를 호출하면 안 된다.** CJS 본문이 provider 파일 **평가 시점**에 실행돼 (a) CJS↔CJS 순환이 `TypeError: require_a is not a function` 으로 죽고 (b) 조건부 `require` 의 부수효과가 무조건 시작 시 실행된다. node 는 require 가 lazy 라 순환을 정상 처리한다. 래퍼 **선언만** 내보내 호출 시점을 소비자에게 남겼다(rolldown 은 eager 호출이라 같은 순환 위험을 안는다).
- **CJS 로부터의 named re-export** 가 `SyntaxError: Identifier 'foo' has already been declared` 였다 — `imports_from` 에 등록된 export 명을 심볼 분기가 먼저 가져갔다. 래퍼 분기를 **먼저** 보게 했다.
- ⚠️ **헬퍼 게이트 회귀**: `needs_to_esm_runtime` 단독 통과를 허용했더니 일반 `--splitting` 이 깨졌다 — `needsRequireShimForChunk` 가 순수 ESM 청크에서도 돌아 `import { createRequire }` 를 중복으로 깔았다(**파싱 불가**). preserve-modules 로 좁히고 `__toESM` 만 내도록 수정.
