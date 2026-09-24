// for-await 본문(일반 경로 방문) 안 for-in 이 yield + 캡처를 가질 때. #4746 3단계(for-await 공통 풀이)에서 해소 예정.
const fns = [];
async function* gLong(sLong, tLong) {
  for await (const aLong of sLong) {
    for (const bLong in tLong) {
      fns.push(() => bLong);
      yield aLong + bLong;
    }
  }
}
(async () => {
  const out = [];
  for await (const vLong of gLong([1, 2], { x: 1, y: 2 })) out.push(vLong);
  console.log(out.join(), fns.map((fLong) => fLong()).join());
})();
