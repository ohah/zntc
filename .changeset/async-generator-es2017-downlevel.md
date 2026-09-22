---
'@zntc/core': patch
---

`--target=es2017` 에서 `async function*` 이 다운레벨되지 않던 문제를 고쳤습니다 (#4628).

async generator 는 **ES2018** 문법인데, 낮추기 호출이 "async 를 지원하지 않는 타겟인가" 검사 **안에 중첩**돼 있었습니다. es2017 은 async 도 generator 도 네이티브라 그 검사에 걸리지 않아, 타겟이 **파싱조차 못 하는** `async function*` 이 그대로 출력됐습니다. es5·es2015·es2016 이 멀쩡했던 건 `async_await` 비트가 켜져 우연히 걸렸기 때문입니다. 이제 자기 비트(`async_generator`, ES2018)로 게이트합니다.

같이 고친 것: 낮춰진 async generator 안의 **`yield*` 위임**이 런타임에 깨지고 있었습니다(es5·es2015·es2016 에 이미 있던 결함). `__asyncGenerator` 의 inner 는 동기 generator 라, async iterable 에 `Symbol.iterator` 를 찾다 `is not iterable` 로 죽었습니다. tslib 호환 `__asyncDelegator` 를 추가해 `yield* X` 를 `yield __await(yield* __asyncDelegator(__asyncValues(X)))` 로 변환합니다.

esnext 부터 es5 까지 6개 타겟이 **동일한 런타임 결과**를 내는 것을 확인했습니다 — sync iterable 위임, 위임 반환값, 중첩 위임, `throw` 전파와 `catch`/`finally`, 조기 `return()` 전파 포함.
