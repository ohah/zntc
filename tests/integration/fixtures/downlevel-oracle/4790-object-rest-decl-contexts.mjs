// 객체 rest 선언 — static 블록·형제 함수 같은 임시 이름·제너레이터·async·반복별 클로저 (#4790)
const out = [];
// static 블록
class Holder {
  static {
    const { valueLong, ...otherLong } = { valueLong: 2, z: 3 };
    Holder.v = valueLong + Object.keys(otherLong).length;
  }
}
out.push(Holder.v);
// 형제 함수가 같은 임시 변수 이름을 쓴다
function one(o) {
  const { keyLong, ...remLong } = o;
  return keyLong + Object.keys(remLong).length;
}
function two(o) {
  let { keyLong, ...remLong } = o;
  keyLong += 10;
  return keyLong + Object.keys(remLong).length;
}
out.push(one({ keyLong: 1, q: 1 }), two({ keyLong: 1 }));
// 제너레이터·async 안
function* gen(o) {
  const { gLong, ...gRest } = o;
  yield gLong;
  yield Object.keys(gRest).join();
}
out.push([...gen({ gLong: 'g', m: 1, n: 2 })].join('|'));
async function run(o) {
  const { aLong, ...aRest } = await o;
  return aLong + Object.keys(aRest).length;
}
// 반복마다 새 바인딩 (클로저)
const fns = [];
for (const item of [
  { idLong: 1, x: 1 },
  { idLong: 2, x: 2 },
]) {
  const { idLong, ...extraLong } = item;
  fns.push(() => idLong + extraLong.x);
}
out.push(fns.map((f) => f()).join());
run(Promise.resolve({ aLong: 5, b: 1 })).then((v) => {
  out.push(v);
  console.log(out.join(','));
});
