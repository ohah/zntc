// strict 함수 안 for-in 풀이 — 합성 임시 변수가 모두 선언돼야 한다(암묵적 전역 금지).
function* gLong(oLong) {
  'use strict';
  for (const kLong in oLong) yield kLong;
}
console.log([...gLong({ a: 1, b: 2 })].join());
