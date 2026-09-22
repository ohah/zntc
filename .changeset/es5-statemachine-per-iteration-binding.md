---
'@zntc/core': patch
---

`--target=es5` 에서 generator/async 함수 안의 루프가 `let`/`const` 의 **반복별 바인딩**을 잃어 클로저가 전부 마지막 값을 캡처하던 문제를 고쳤습니다 (#4716).

```js
function* g() {
  const fns = [];
  for (let i = 0; i < 3; i++) { fns.push(() => i); yield i; }
  fns.forEach(f => console.log(f()));
}
[...g()];
// 네이티브: 0 1 2   /  es5(이전): 3 3 3   ← 에러 없이 값만 틀림
```

`yield`/`await` 이 있는 함수는 상태 기계로 접히면서 지역 변수를 함수 최상단 `var` 로 호이스트합니다. 그때 반복별 바인딩이 사라집니다. 일반 경로는 본문을 `_loopN` 함수로 추출해 이를 복원하는데, 상태 기계 경로는 본문에 `yield` 가 있어 평범한 함수로 뽑을 수 없었습니다. 이제 **generator 로 뽑고 `yield*` 로 위임**합니다(`[5, __values(_loopN(x))]`) — `yield*` 의 값이 `_loopN` 의 return 값이라 `break`/`continue`/`return` 신호도 그대로 실려 옵니다.

`for`·`for…of`·`for…in` 모두, generator 와 async 함수 모두 해당합니다. 클로저 캡처가 없으면 추출하지 않으므로 기존 출력은 그대로입니다.

⚠️ 라벨 붙은 `break`/`continue` 가 바깥 루프를 겨냥하는 경우는 아직 추출하지 않습니다(라벨×es5 는 #4710 에서 별도로 다룹니다).

`--minify` 에서 합성 temp(`_loopN`, `_ret`)의 대입 좌변이 리네임에서 빠져 `ReferenceError` 가 나던 문제도 함께 고쳤습니다.
