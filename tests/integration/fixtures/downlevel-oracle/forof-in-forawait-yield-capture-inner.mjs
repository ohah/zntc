// 바깥 for-await 는 추출되지 않고(a 미캡처) 안쪽 for-of 만 캡처 — 안쪽 루프가 일반 경로에서
// 풀리며 yield 가 든 본문을 generator 로 뽑아야 한다 (#4722 → #4746).
const fns = [];
async function* g(s, t) {
  for await (const a of s) {
    for (const b of t) {
      fns.push(() => b);
      yield a + b;
    }
  }
}
(async () => {
  const out = [];
  for await (const v of g([1, 2], ['x', 'y'])) out.push(v);
  console.log(out.join(), fns.map((f) => f()).join());
})();
