---
'@zntc/core': patch
---

minify 없이 번들할 때 async/generator **메서드**와 `async function*` 의 런타임 헬퍼 정의가 빠져 실행 즉시 `ReferenceError` 가 나던 문제를 고쳤습니다 (#4727).

```js
const o = { async m() { return 1; } };        // es5~es2016: __async is not defined
async function* ag() { yield 1; }             // es2017·node8·chrome60·safari11: __asyncGenerator is not defined
```

번들러는 변환이 필요한 모듈만 미리 골라 헬퍼를 번들에 등록하는데, 이 판정이 객체 메서드를 보지 않았고 async generator 를 async·generator 따로만 봤습니다. `--minify` 는 판정과 무관하게 항상 변환해서 가려져 있었습니다.
