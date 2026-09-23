---
'@zntc/core': patch
---

`using` / `await using` 낮추기의 여러 결함을 고쳤습니다 (#4730).

- **es5·Hermes**: 블록·함수 본문·generator/async 안의 `using` 이 dispose 없이 `var` 가 되어 `[Symbol.dispose]` 가 호출되지 않았습니다.
- **모든 낮추기 타겟**
  - `_stack`/`_error`/`_hasError` 가 고정 이름이라 중첩 블록이 바깥 스택을 덮어쓰고, 사용자 변수 `_stack` 과도 충돌했습니다.
  - 앞 블록(또는 이전 반복)에서 잡힌 에러 상태가 남아, 에러 없이 끝난 블록이 옛 에러를 다시 던졌습니다.
  - 첫 `using` 뒤의 함수 선언이 try 블록 안으로 들어가 앞쪽 문장에서 호출할 수 없었습니다(`g is not a function`).
  - 모듈 최상위 `using` 뒤의 `export` 가 try 안에 들어가 문법 오류가 났습니다.
  - `for (using x of …)` 헤더는 전혀 낮춰지지 않았습니다.

```js
{ using a = res(); { using b = res(); } }   // 이전: 바깥 a 가 dispose 되지 않음
```
