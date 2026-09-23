---
'@zntc/core': patch
---

객체 리터럴 메서드 `super` 낮추기(#4729)가 만드는 `_obj` 파라미터가 같은 이름의 사용자 변수를 가리던 문제를 고쳤습니다.

```js
const _obj = 5;
const o = { __proto__: p, a: _obj, async n() { return super.m(); } };
// 이전(es5·es2016): o.a === undefined   /  이제: 5
```

기존 이름 충돌 검사는 `_a`·`_b2` 같은 임시 변수 패턴만 봐서 `_obj` 를 걸러내지 못했습니다. 이제 소스에 식별자로 나오는 이름은 피합니다(`_obj2`, …).
