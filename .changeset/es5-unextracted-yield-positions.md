---
'@zntc/core': patch
---

`--target=es5` 에서 일부 자리의 `yield` 가 추출되지 않아 **산출물이 파싱조차 되지 않던** 문제를 고쳤습니다 (#4721).

```js
function* g() {
  const o = { ['k' + (yield 1)]: 2 };         // 객체 리터럴 computed key
  obj[yield 'k'] = 1;                          // computed 멤버가 대입 좌변
  for (let i = (yield 'i'); i < 2; i += (yield 'u')) use(i);   // for 의 init / update
}
// es5(이전): SyntaxError: Unexpected strict mode reserved word
```

추출되지 않은 `yield` 가 `__generator` 콜백(평범한 함수) 안에 raw 로 남아 번들 전체가 로드되지 않았습니다. 원인은 세 가지였습니다 — computed key 를 감싸는 노드를 순회하지 않음, 대입문이 **우변만** 검사, `for` 가 **본문과 조건만** 검사.

클래스의 computed 메서드 키(`class { [yield k]() {} }`)는 클래스 lowering 층의 문제라 #4723 에서 따로 다룹니다.
