// yield 없는 라벨 for-of 는 상태 기계 안에서도 native 루프로 남는다 — 라벨이 풀이 결과
// 안쪽 for 에 붙어야 `continue outer` 가 유효하다 (#4746).
function* gLong() {
  let sLong = 0;
  const seen = [];
  outer: for (const xLong of [1, 2, 3]) {
    for (const yLong of [0, 1]) {
      if (xLong === 2) continue outer;
      if (xLong === 3 && yLong === 1) break outer;
      sLong += xLong;
      seen.push(xLong + '' + yLong);
    }
  }
  yield seen.join();
  return sLong;
}
const it = gLong();
console.log(it.next().value, it.next().value);
