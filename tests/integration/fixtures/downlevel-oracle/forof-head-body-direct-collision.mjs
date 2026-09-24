// 헤더 바인딩과 같은 이름을 본문 블록이 직접 다시 선언한다(헤더와 본문은 스코프가 다르다).
const out = [];
const fns = [];
for (const x of [1, 2]) {
  let x = 'b';
  out.push(x);
  fns.push(() => x);
}
for (let y of [3]) {
  const y = 'c';
  out.push(y);
}
function* g() {
  for (const z of [5, 6]) {
    let z = 'z';
    yield z;
    fns.push(() => z);
  }
}
for (const v of g()) out.push(v);
console.log(out.join(), fns.map((f) => f()).join());
