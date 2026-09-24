// 캡처로 본문이 `_loop` generator 로 추출되고, 그 안에서 또 for-in 을 풀어 자기 임시 변수를
// 만든다 — 바깥 풀이의 키 배열·인덱스 이름이 안쪽 임시 변수에 가려지면 안 된다.
const fns = [];
function* gLong(oLong) {
  for (const kLong in oLong) {
    yield kLong;
    fns.push(() => kLong);
    for (const jLong in oLong) {
      const mLong = oLong[jLong]?.v ?? 'd';
      yield kLong + jLong + mLong;
    }
  }
}
console.log([...gLong({ a: { v: 1 }, b: null })].join(), fns.map((fLong) => fLong()).join());
