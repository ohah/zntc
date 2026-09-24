// 캡처로 본문이 반복별 함수로 추출되고, 그 안에서 또 루프·옵셔널 체인을 풀어 자기 임시
// 변수를 만든다 — 바깥 풀이의 step 이름이 가려지면 안 된다.
const fns = [];
const out = [];
(async () => {
  for await (const vLong of [{ n: 1 }, null]) {
    fns.push(() => vLong);
    for (const wLong of [vLong]) out.push(wLong?.n ?? 'x');
    for (const kLong in vLong ?? {}) out.push(kLong);
  }
  console.log(out.join(), fns.map((fLong) => JSON.stringify(fLong())).join());
})();
