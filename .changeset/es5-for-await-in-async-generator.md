---
'@zntc/core': patch
---

`--target=es5` 에서 async generator 안의 `for await` 이 런타임에 터지던 문제를 고쳤습니다 (#4707).

```js
async function* mid() { for await (const v of [1, 2]) yield v * 10; }
// es5: TypeError: Cannot read properties of undefined (reading 'done')
```

es5 에서 async generator 의 안쪽은 **동기** generator 라, "await" 과 "yield" 가 `[4, x]` 라는 같은 op 로 나갑니다. 둘을 가르는 건 값이 `__await(…)` 로 감싸였는지 뿐인데, `for await` 다운레벨은 state machine 을 **만드는 도중에** 새 await 을 만들어 그 포장 시점을 놓쳤습니다. 감싸지 않으면 `__asyncGenerator` 가 그 값을 소비자에게 내보낼 yield 로 처리해 `_state.sent()` 가 `undefined` 가 됩니다.

평범한 async 함수의 `for await`(`__async` 경로)은 raw yield 를 쓰므로 그대로입니다. es2015 이상 타겟은 안쪽이 네이티브 generator 라 영향이 없습니다.
