---
'@zntc/core': patch
---

다운레벨된 async generator 에서 `yield*` 위임 중 `.return(v)` 의 `value` 가 유실되던 문제를 고쳤습니다 (#4700).

```js
async function* inner() { yield 1; yield 2; }
async function* deleg() { yield* inner(); }
const g = deleg(); await g.next();
await g.return('V');
// 이전 (es2017 이하): { done: true }            ← value 유실
// 현재:               { value: 'V', done: true }
```

원인은 tslib 의 `__asyncDelegator` 설계였습니다 — `p` 플래그를 토글하는 방식이라 위임의 **완료값**을 실어 나를 자리가 없습니다(tslib 구현 그대로 바꿔치기해도 동일했습니다). esbuild 방식으로 바꿨습니다: `__await` 에 "이 await 는 `yield*` 에서 왔다" 표시를 더하고, `__asyncGenerator` 가 그 표시를 보면 resolved 값을 `{done, value}` 그대로 되돌리며 `return` 메서드를 보존해 재개합니다. `__asyncDelegator` 는 `__yieldStar` 하나로 대체돼 동기/비동기 대상을 모두 처리합니다.

`for await … break`, `finally` 실행 순서, `throw()` 전파, `next(v)` 인자 전달은 이전에도 정상이었고 그대로입니다.
