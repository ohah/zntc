---
'@zntc/core': patch
---

`async *m() {}` **메서드**가 다운레벨되지 않던 문제를 고쳤습니다 (#4628 후속).

#4628 은 최상위 `async function*` 만 덮었습니다. 클래스/객체 메서드는 각각 다른 경로를 타서, `class C { async *m() {} }` 가 **es2015·es2016·es2017 에서 그대로 남아** 타겟 엔진이 파싱조차 못 했습니다. es2015/es2016 은 이전부터 있던 결함이고, es2017 은 #4628 의 범위인데 수정이 닿지 않았습니다.

같이 고친 것:

- **es5 에서 async generator 메서드가 Promise 를 돌려줬습니다.** class→함수 낮추기 경로가 이를 일반 async 처럼 `__async(...)` 로 감싸, `for await` 이 `o[Symbol.iterator] is not a function` 으로 죽었습니다. 기존 결함입니다.
- **`super` 가 든 async generator 메서드.** 본문이 home object 없는 `function*` 으로 옮겨지므로 raw `super` 는 SyntaxError 입니다 — 추출 컨텍스트를 켜 `__superGet(...)` 으로 낮춥니다.

esnext·es2022·es2018 에서는 네이티브 `async *m()` 을 그대로 둡니다.
