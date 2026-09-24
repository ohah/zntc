// yield 없는 라벨 for-of 는 상태 기계 안에서도 native 루프로 남는다 — 라벨이 풀이 결과
// 안쪽 for 에 붙어야 `continue outer` 가 유효하다 (#4746).
function* g() {
  let s = 0;
  const seen = [];
  outer: for (const x of [1, 2, 3]) {
    for (const y of [0, 1]) {
      if (x === 2) continue outer;
      if (x === 3 && y === 1) break outer;
      s += x;
      seen.push(x + '' + y);
    }
  }
  yield seen.join();
  return s;
}
const it = g();
console.log(it.next().value, it.next().value);
