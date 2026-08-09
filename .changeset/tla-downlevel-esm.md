---
"@zntc/core": patch
---

`--target < es2022` 에서 top-level await 산출물이 **타겟 엔진에서 파싱조차 안 되던** 문제를
고쳤다 (#4598). React Native 는 Hermes 가 거부해 앱이 아예 뜨지 않았다.

`es2022_tla.lowerProgram` 이 `export const x = await f()` 를 건너뛰어 await 가 최상위에
남았다. 이제 그 선언(과 그 바인딩에 의존하는 후속 선언)을 async IIFE 로 옮기고, `__esm`
factory 가 **초기화 완료 promise** 를 돌려주도록 해 소비자가 기다릴 수 있게 했다.

⚠️ await 와 무관한 export 는 지연하지 않는다 — `await …;` 뒤의 `export const NAME='hello'`
까지 옮기면 소비자가 `undefined` 를 읽는다.

남은 범위: es5(Hermes preset)는 소비자 체이닝이 필요해 값이 아직 `undefined` 다(파싱은 정상).
`require()` 로 TLA 모듈을 소비하는 위상은 Node 도 `ERR_REQUIRE_ASYNC_MODULE` 로 거부한다.
