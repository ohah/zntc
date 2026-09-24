// for-await 본문은 일반 경로로 방문돼 안쪽 for-of 가 일반 경로에서 풀린다 — 본문에 yield 와
// 캡처가 함께 있으면 generator 로 뽑아야 한다 (#4722 → #4746 visitForStatement 이식).
const fns = [];
async function* gLong(sLong, tLong) {
  for await (const aLong of sLong) {
    for (const bLong of tLong) {
      fns.push(() => aLong + bLong);
      yield bLong;
    }
  }
}
(async () => {
  const out = [];
  for await (const vLong of gLong([1, 2], ['x', 'y'])) out.push(vLong);
  console.log(out.join(), fns.map((fLong) => fLong()).join());
})();
