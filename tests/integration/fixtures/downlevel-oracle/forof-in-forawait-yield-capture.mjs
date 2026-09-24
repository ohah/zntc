// for-await 본문은 일반 경로로 방문돼 안쪽 for-of 가 일반 경로에서 풀린다 — 본문에 yield 와
// 캡처가 함께 있으면 generator 로 뽑아야 한다 (#4722 → #4746 visitForStatement 이식).
const fns = [];
async function* g(s, t) {
  for await (const a of s) {
    for (const b of t) {
      fns.push(() => a + b);
      yield b;
    }
  }
}
(async () => {
  const out = [];
  for await (const v of g([1, 2], ['x', 'y'])) out.push(v);
  console.log(out.join(), fns.map((f) => f()).join());
})();
