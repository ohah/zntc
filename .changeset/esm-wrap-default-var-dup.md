---
'@zntc/core': patch
---

ESM-wrap 된 모듈에서 `function foo(){}; export default foo` 형태가 `var foo;` 와
`function foo(){}` 를 동시에 top-level 로 내보내 브라우저 파싱이 `SyntaxError:
Identifier 'foo' has already been declared` 로 중단되던 문제를 고쳤다.

`@mui/material` 의 `createTheme` 이 끌어오는 `@mui/utils/esm/clamp/clamp.js` 가 정확히
이 형태라, MUI 를 쓰는 앱에서 번들은 성공하지만 브라우저가 로드하지 못했다. 진단도 없었다.

두 경로가 같은 이름을 낸다 — 함수 선언은 `hoisted_stmts` 로, `export default` 는
`hoisted_var_names` 로. 중복 제거가 `hoisted_var_names` **내부만** 봐서 둘 사이 충돌을
못 잡았다. 호이스팅된 함수 이름을 함께 모아 같은 필터에서 걸러낸다 (#4574 가
`helper_import_locals` 로 거른 것과 같은 자리).
