---
"@zntc/core": patch
---

`--target=es2015` / `es2016` 에서 `for await` 를 쓰면 방출된 코드가 **파싱조차 되지 않던** 버그 수정 (#4488).

```js
async function f(xs) { for await (const x of xs) use(x); }
```
→ `function f(xs){ return __async(function*(){ ... await _a.next() ... }); }` — generator 안에 `await` 가 남아 `'await' is not allowed in non-async function`.

`for await` 다운레벨이 만드는 `await` 노드는 body 를 **방문하는 도중에** 생겨서, 이미 지나간 async lowering 의 방문(`await` → `yield`)을 받지 못했다. `async function` / `async function*` / `async` 화살표 세 경로 모두 해당. async lowering 이 body 를 visit 한 뒤 남은 await 를 정리하는 post-pass 를 추가했다.
