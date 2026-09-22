---
'@zntc/core': patch
---

`--target=es5` 에서 라벨 붙은 `for await` 의 `continue <label>` 이 **바깥 루프를 끊던** 문제를 고쳤습니다 (#4710).

```js
async function* g() {
  outer: for await (const a of [1, 2]) {
    for await (const b of ['x', 'y']) { if (b === 'y') continue outer; yield a + b; }
  }
}
// 네이티브: 1x, 2x  /  es5(이전): 1x   ← 바깥 루프가 한 바퀴 만에 끝남
```

상태 기계의 라벨 처리에서 **`for await` 만 "루프"로 분류되지 않아** `continue` 대상이 없었고, `continue` 가 `break` 로 떨어졌습니다. 동기 `for…of` 를 가로지르는 라벨은 정상이었습니다. `break <label>` · `try/finally` · `switch` 와의 조합, 평범한 async 함수 안에서도 동일하게 고쳐집니다.
