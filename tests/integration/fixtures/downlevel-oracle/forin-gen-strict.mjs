// strict 함수 안 for-in 풀이 — 합성 임시 변수가 모두 선언돼야 한다(암묵적 전역 금지).
function* g(o) {
  'use strict';
  for (const k in o) yield k;
}
console.log([...g({ a: 1, b: 2 })].join());
