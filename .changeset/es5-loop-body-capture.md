---
'@zntc/core': patch
---

es5·Hermes 에서 루프 **본문**에서 선언한 `let`/`const`/`class` 를 클로저가 캡처하면 모든 클로저가 마지막 값을 보던 문제를 고쳤습니다 (#4743).

```js
const fns = [];
for (var i = 0; i < 2; i++) { const v = i * 10; fns.push(() => v); }
fns.map(f => f());   // 네이티브: [0, 10]   /  이전(es5): [10, 10]
```

- 반복별 추출(`_loop`)이 루프 헤더의 `let` 이 캡처될 때만 켜지던 것을 본문 선언까지 넓혔습니다. while / do-while 은 추출 경로가 없었는데 새로 추가했습니다. generator/async 안에서는 catch 파라미터도 포함합니다.
- 루프 본문을 함수로 뽑을 때 본문의 `var` 가 그 함수 안에 갇혀 루프 밖에서 `ReferenceError` 가 나던 문제도 함께 고쳤습니다(바깥으로 끌어올림).
