// 헤더 바인딩과 같은 이름을 본문 블록이 직접 다시 선언한다(헤더와 본문은 스코프가 다르다).
const out = [];
const fns = [];
for (const xLong of [1, 2]) {
  let xLong2 = 'b';
  out.push(xLong2);
  fns.push(() => xLong2);
}
for (let yLong of [3]) {
  const yLong2 = 'c';
  out.push(yLong2);
}
function* gLong() {
  for (const zLong of [5, 6]) {
    let zLong2 = 'z';
    yield zLong2;
    fns.push(() => zLong2);
  }
}
for (const vLong of gLong()) out.push(vLong);
console.log(out.join(), fns.map((fLong) => fLong()).join());
