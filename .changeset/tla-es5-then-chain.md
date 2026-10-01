---
"@zntc/core": patch
---

React Native(Hermes) 에서 top-level await 를 쓰는 의존성이 있으면 **앱이 아예 뜨지 않던**
문제를 고쳤다 (#4598).

es5 계열 타겟(Hermes preset 포함)에서는 `__esm` factory 를 async 로 만들 수 없다. 그래서
직전 수정은 그 위상에서 lowering 을 껐는데, 그러면 `v = yield …` 가 generator 가 아닌
factory 에 남아 Hermes 가 번들을 거부했다.

이제 es5 에서도 lowering 을 하고, 소비자는 **promise 체이닝**으로 기다린다:

```js
"app.ts"() { return Promise.all([init_dep()]).then(function() { … }); }
```

`init_X()` 가 돌려주는 것은 이미 낮춰진 `__async(...)` promise 이므로 상태머신 없이
순수 ES5 문법으로 성립한다. hermesc 통과 + 값 정확성 둘 다 확인했다.
