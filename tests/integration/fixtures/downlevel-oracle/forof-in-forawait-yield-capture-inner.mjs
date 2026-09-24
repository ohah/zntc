// 바깥 for-await 는 추출되지 않고(a 미캡처) 안쪽 for-of 만 캡처 — 안쪽 루프가 일반 경로에서
// 풀리며 yield 가 든 본문을 generator 로 뽑아야 한다 (#4722 → #4746).
const fns = [];
async function* gLong(sLong, tLong) {
  for await (const aLong of sLong) {
    for (const bLong of tLong) {
      fns.push(() => bLong);
      yield aLong + bLong;
    }
  }
}
(async () => {
  const out = [];
  for await (const vLong of gLong([1, 2], ['x', 'y'])) out.push(vLong);
  console.log(out.join(), fns.map((fLong) => fLong()).join());
})();
