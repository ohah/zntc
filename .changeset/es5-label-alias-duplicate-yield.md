---
'@zntc/core': patch
---

`--target=es5` 에서 라벨 스코프가 끝나는 자리에 `yield` 가 오면 **그 값이 두 번 방출되던** 문제를 고쳤습니다 (#4718).

```js
async function* g() {
  B: for await (const v of [1, 2]) {
    C: { if (v === 1) break C; yield 'b' + v; }
  }
  yield 'end';        // ← es5 에서 두 번 나왔다
}
```

상태 기계는 라벨 스코프 끝에 `nop` 을 넣어 라벨을 표시합니다. 그 자리에 이미 다른 라벨(예: `try` 영역 종료)이 있으면 두 라벨이 같은 위치를 가리켜 `case 14: case 15: return [4, v]` 가 됩니다. `__generator` 의 `yield`(op 4)·`yield*`(op 5)는 재개 위치를 **현재 라벨 + 1** 로 잡으므로, 14 로 진입하면 재개가 15 = 같은 yield 가 되어 값이 한 번 더 나갑니다.

이제 빈 case 뒤에 yield 가 오는 경우에만 명시 점프를 넣어 라벨과 실행 위치를 맞춥니다. 해당하지 않는 코드의 출력 크기는 그대로입니다(실측: 해당 지점만 +13B, 나머지 0B).
