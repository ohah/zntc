---
"@zntc/core": patch
---

`--preserve-modules`(ESM 출력)에서 **익명 `export default class {}` / `function(){}`** 를 낸 모듈이 ESM-wrap 되면 `SyntaxError: Export '_default' is not defined` 로 모듈이 로드되지 않던 것 수정 (#4573).

```js
// b.js:  export default class { greet(){ return "hi"; } }
// a.cjs: module.exports = require("./b.js");   // b 를 ESM-wrap 강제
// entry: import D from "./b.js"; import "./a.cjs"; console.log(new D().greet());
```

## 근본 원인

ESM-wrap lowering(`esm_wrap.zig`)은 export 를 `__esm(() => {…})` 클로저 밖 top-level 로 hoist 한다(`var X;` 선언 + 클로저 안 `X = …` 할당). `.class_declaration` 분기는 **클래스 이름이 있을 때만** 그 이름을 hoist 했다. 익명 default class 는 이름이 없어 synthetic `_default` 의 `var _default;` 가 hoist 되지 않았고, codegen 은 클로저 안에서 `_default = class {…}` 로 할당 + top-level `export { _default }` 를 방출 → 미선언 참조.

value/arrow default(`export default expr` / `() => …`)는 `effective_tag` 가 선언이 아니라 `else` 분기가 이미 `_default` 를 hoist 했고, named class·function, 익명 function 도 정상이었다.

## 수정

익명이고 `export default` 면 `default_export_name`(`_default`)을 hoist 한다:
- `.class_declaration` 분기(`class_name_idx.isNone()`) — 익명 default class.
- `.function_declaration` strict_execution_order 분기(`fn_name_idx.isNone()`) — 익명 default function. `/code-review max` 적발: RN 프리셋(strict)에서 codegen 이 `_default = function(){}` 로 할당해 class 와 동일 버그. 5곳으로 중복돼 있던 default 이름 파생을 `defaultExportName` 헬퍼로 통합.

## 검증

- 회귀 스위트 `preserve-modules-default-export.test.ts`: default 형태(익명 class/function/arrow/extends, named class/function, value) × esm/cjs × plain/minify + **익명 function RN(strict)** — 전부 통과(익명 class ESM·익명 function RN 이 수정 전 실패).
- 방출: `var _default;` top-level 선언 + 클로저 안 `_default = class {…}`/`_default = function(){}` + `export { _default }` 일관.
- zig 전체 test, 통합 스위트 무회귀.

## 별개 잔여 (이 PR 범위 밖)

- **RN downlevel class 헬퍼 중복**(#4574): `--preserve-modules --platform=react-native` 에서 class 를 export 하면 다운레벨 헬퍼(`__classCallCheck`/`__extends`)가 import + hoisted var 로 이중 선언 → SyntaxError. 익명·named·default 무관(class 다운레벨 특정).

Refs #4573
