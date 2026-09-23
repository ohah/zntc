---
'@zntc/core': patch
---

es5·Hermes 에서 generator/async 함수 안의 catch 파라미터와 블록 스코프 바인딩이 바깥 동명 변수를 덮던 문제를 고쳤습니다 (#4712).

```js
const err = 'OUTER';
function* g() {
  try { yield 1; throw new Error('A'); }
  catch (err) { err = new Error('B'); yield 'rec'; }
  console.log(err);   // 네이티브: OUTER   /  이전(es5): Error: B
}
```

상태 기계가 catch 파라미터·중첩 블록 `let`/`const`·루프 헤더 `let` 을 원래 이름 그대로 함수 최상단 `var` 로 끌어올려 블록 스코프를 잃었습니다. 이제 고유 이름(`err$1`)으로 바꿔 올립니다. 함께 고친 것:

- `yield` 없는 평범한 catch 의 파라미터까지 끌어올리던 문제
- 구조분해 catch 파라미터(`catch ({ message })`)의 es5 문법 잔존과 minify 이름 불일치
- 구조분해 기본값 분기가 리네임된 이름을 속성 키로 쓰던 문제(`_a.message$1`)
- 기본값이 붙은 중첩 패턴(`{ b: [c] = d }`)이 es5 에서 낮춰지지 않던 문제
