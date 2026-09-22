---
'@zntc/core': patch
---

클래스 메서드의 `async` / `generator` 가 타겟에 맞춰 다운레벨되지 않던 문제를 고쳤습니다 (#4699).

- **`async m()` @ `--target=es2015` · `es2016`** — `async` 는 ES2017 인데 그대로 남아 타겟 엔진이 파싱조차 못 했습니다.
- **`*m()` @ `--target=es5`** — class→함수 낮추기 경로가 `is_async` 만 분기해서, generator 단독은 플래그가 보존된 채 `function*` 으로 남았습니다.

같은 모양이라도 최상위 함수와 객체 리터럴 메서드는 정상이었습니다 — **클래스 메서드만** 별도 dispatch 라 어느 낮추기 경로도 타지 않았습니다. `async *m()`(#4628)이 쓰던 훅을 세 축(`async` / `generator` / `async generator`)으로 일반화했습니다.

`super` 를 쓰는 메서드도 함께 처리합니다 — 본문이 다른 함수로 옮겨지므로 `__superGet(...)` 으로 낮춥니다. 네이티브로 지원하는 타겟(es2017 의 `async`, es2015 의 generator)에서는 그대로 둡니다.

같이 고친 것 — **`arguments` 캡처**. 본문이 `__async(function*(){…})` / `__generator(this, function(_state){…})` 안쪽으로 옮겨지면 `arguments` 가 **그 안쪽 함수의 것**을 가리킵니다. `this` 는 `.call(this)` 로 따로 전달되는데 `arguments` 만 빠져 있었고(arrow 다운레벨에만 걸린 게이트), 최상위 함수·객체 메서드에도 이미 있던 결함입니다.

```js
// 수정 전, --target=es2015
async function f() { return arguments; }
→ function f() { return __async(function*() { return arguments; }).call(this); }  // 빈 arguments
// --target=es5 의 generator 는 `[_state]` 를 가리켜 `[object Object]` 가 나왔습니다.
```

이제 바깥 wrapper 가 `var _arguments = arguments` 를 선언하고 본문이 그걸 참조합니다. `async *` 는 `__asyncGenerator(this, arguments, fn)` 이 이미 인자로 넘기므로 그대로 둡니다.
