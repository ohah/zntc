// for-await 본문(일반 경로 방문) 안 for-in 이 yield + 캡처를 가질 때. #4746 3단계(for-await 공통 풀이)에서 해소 예정.
const fns = [];
async function* g(s, t) {
  for await (const a of s) {
    for (const b in t) {
      fns.push(() => b);
      yield a + b;
    }
  }
}
(async () => {
  const out = [];
  for await (const v of g([1, 2], { x: 1, y: 2 })) out.push(v);
  console.log(out.join(), fns.map((f) => f()).join());
})();
