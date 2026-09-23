---
'@zntc/core': patch
---

객체 리터럴 메서드 안 `super` 가 그 객체의 프로토타입이 아니라 `Object.prototype` 을 보던 문제를 고쳤습니다 (#4729).

```js
const o = { __proto__: { m() { return 1; } }, n() { return super.m(); } };
o.n();
// 네이티브: 1   /  이전(es5·Hermes): TypeError
```

- **es5·Hermes**: 메서드가 함수로 바뀌면서 `super` 기준을 잃었습니다. 클래스 메서드 안의 객체 리터럴이면 바깥 클래스의 부모를 보았습니다(조용히 틀린 값).
- **es2015·es2016 등**: async/generator 객체 메서드의 본문이 generator 함수로 옮겨지면서 native `super` 가 남아 `SyntaxError` 가 났습니다.
- getter·대입·옵셔널 체인의 `super` 가 minify 없이 번들할 때 `__superGet`/`__superSet` 정의 없이 호출만 남던 문제도 함께 고쳤습니다.

객체를 평가할 때마다 새 바인딩(`((_obj) => _obj = {…})()`, es5 는 `function`)에 담고 `Object.getPrototypeOf(_obj)` 를 기준으로 삼습니다. 그래서 루프 안에서 만든 객체들도 각자 자기 프로토타입을 봅니다. 또한 es5 에서 `_loop` 으로 추출된 루프 본문의 임시 변수를 `_loop` 안에 선언하도록 바꿨습니다.
