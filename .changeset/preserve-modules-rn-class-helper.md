---
"@zntc/core": patch
---

`--preserve-modules --platform=react-native`(+`--preserve-modules-root`)에서 **class 를 export** 하면 로드 실패하던 것 수정 (#4574).

```js
// b.js:  export class Bar { greet(){ return "bar"; } }
// a.cjs: module.exports = require("./b.js");   // b 를 ESM-wrap 강제
// entry: import { Bar } from "./b.js"; import "./a.cjs"; console.log(new Bar().greet());
```

RN 다운레벨은 class 를 `__classCallCheck`/`__extends` 헬퍼로 낮추고 그 헬퍼를 runtime helper **virtual module** 에서 import 한다. 두 버그가 겹쳐 있었다:

## 버그 1 — 헬퍼 이름 이중 선언 (SyntaxError)

transform 이 헬퍼를 `var __classCallCheck = function(){…}` 로 인라인한다. 링커가 그 헬퍼를 별도 모듈에서 `import { __classCallCheck }` 로도 가져오면, 인라인 initializer 는 elide 되지만 ESM-wrap hoisting 이 수집한 **이름**이 import 와 이중 선언(`var __classCallCheck` + `import { __classCallCheck }` → `Identifier '__classCallCheck' has already been declared`).

**수정**: `emitEsmWrappedModule`(esm_wrap.zig)에서 **helper-module import 로컬명을 hoisted var 에서 제외** — import 문이 그 바인딩을 선언하므로 진짜 소스. 단:

- **`preserve_modules` 로 게이트** — non-preserve 는 헬퍼를 별도 모듈에서 import 하지 않고 **inline** 하며(is_helper hoist 의 `var __extends; __extends = …` assign-only preamble, #1209), 그 var 는 필요하다. 제외 필터를 non-preserve 에 걸면 회귀하므로 preserve-modules 로 한정.
- **키는 `getCanonicalByRef`**(rename 반영) — hoisted 이름이 resolveNodeName 이라 raw 로 매칭하면 minify/deconflict 시 놓친다.
- **필터 후 남은 이름이 0 이면 `var` emit 자체를 건너뜀** — 모든 hoisted 이름이 helper import 인 모듈에서 `var ;`(SyntaxError)가 되던 것 방지.

## 버그 2 — 헬퍼 모듈 import 경로 오류 (ERR_MODULE_NOT_FOUND)

virtual helper 모듈은 outdir **최상위**에 놓이는데(bare sanitize id `runtime-class-call-check`), `computeRelativeImportPath` 가 root 아래가 아닌 그 bare id 를 소스의 **원본 절대 dir** 기준으로 상대 계산해 `../../../../runtime-…` 가 됐다.

**수정**: dep 이 bare id(virtual helper)면 outdir 최상위 파일로 취급해 상대 계산. src 가 root 아래면 src_rel dir 에서, **src 도 root 밖이면**(RN 모노레포 hoisted dep) stem-only 로 최상위에 놓이므로 형제 `./runtime-…` 로.

## 검증

- 회귀 스위트 `preserve-modules-rn-class.test.ts` 8종:
  - 4종(esm/cjs × plain/minify): named/익명 default/`extends`/plain function class + 헬퍼 import → `NDPE-B` (수정 전 SyntaxError·ERR_MODULE_NOT_FOUND).
  - `[0]` 2종: non-preserve ESM-wrap × RN downlevel 이 헬퍼 var 를 보존하며 정상 실행(`E-B`).
  - `[1]` 2종: out-of-root 소스의 헬퍼 경로가 `./runtime-…` 로 정상(`W`).
- zig 전체 test, preserve/wrapper/cross-chunk 통합 스위트 무회귀.

## 한계

- `--preserve-modules-root` 미지정 시 virtual helper 경로 계산은 출력 base 추론과 어긋나 여전히 부정확(RN/Metro 는 project root 를 주므로 실사용 영향 없음). 별도 base-추론 이슈로 후속.
- out-of-root **non-helper 모듈**의 entry→module 지정자(같은 dir 이 아닐 때)는 이 PR 범위 밖의 일반 base-추론 문제로 남는다.
