---
'@zntc/core': patch
---

클래스 메서드의 `async` / `generator` 가 타겟에 맞춰 다운레벨되지 않던 문제를 고쳤습니다 (#4699).

- **`async m()` @ `--target=es2015` · `es2016`** — `async` 는 ES2017 인데 그대로 남아 타겟 엔진이 파싱조차 못 했습니다.
- **`*m()` @ `--target=es5`** — class→함수 낮추기 경로가 `is_async` 만 분기해서, generator 단독은 플래그가 보존된 채 `function*` 으로 남았습니다.

같은 모양이라도 최상위 함수와 객체 리터럴 메서드는 정상이었습니다 — **클래스 메서드만** 별도 dispatch 라 어느 낮추기 경로도 타지 않았습니다. `async *m()`(#4628)이 쓰던 훅을 세 축(`async` / `generator` / `async generator`)으로 일반화했습니다.

`super` 를 쓰는 메서드도 함께 처리합니다 — 본문이 다른 함수로 옮겨지므로 `__superGet(...)` 으로 낮춥니다. 네이티브로 지원하는 타겟(es2017 의 `async`, es2015 의 generator)에서는 그대로 둡니다.
