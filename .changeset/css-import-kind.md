---
"@zntc/core": patch
---

CSS `@import "base.css"` 의 `./` 없는 지정자가 tsconfig `paths` 에 가로채여 전혀 다른
스타일시트가 번들되던 문제를 고쳤다 (#4611).

catch-all `paths`(`"*": ["src/*"]`) 가 있으면 `@import "vars.css"` 가 형제 스타일시트 대신
`paths` 가 가리키는 파일로 갔다. `@import "./vars.css"` 는 형제로 가므로 **같은 URL 을 가리키는
두 표기가 서로 다른 스타일시트**가 됐다 — 진단 0건.

`@import` 레코드에 전용 kind(`css_import`)를 도입해 `url()` / `new URL()` 과 같은 URL 참조
축으로 편입했다. JS 의 `import "normalize.css"` 는 종전대로 npm 패키지로 해석된다 — 예전엔
둘이 같은 kind 라 규칙을 나눌 수 없었다.
