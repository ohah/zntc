// 객체 rest 선언의 임시 변수 — 같은 스코프 export const·함수 최상위 let/const 와 끌어올린 var 가 겹치면 안 되고,
// for 헤더 let 은 반복마다 새 바인딩이어야 한다 (#4790)
function pick(objLong) {
  let { aLong, ...rLong } = objLong;
  const { bLong, ...sLong } = objLong;
  return [aLong, rLong, bLong, sLong];
}
console.log(JSON.stringify(pick({ aLong: 1, bLong: 2 })));
let { aLong: topLong, ...topRestLong } = { aLong: 3, c: 4 };
for (let { aLong, ...rLong } = { aLong: 5, n: 1 }; rLong.n < 3; rLong.n++)
  console.log(aLong, rLong.n);
const fns = [];
for (let { iLong, ...restLong } = { iLong: 0 }; iLong < 2; iLong++) fns.push(() => iLong);
console.log(topLong, JSON.stringify(topRestLong), fns.map((f) => f()).join());
switch (1) {
  case 1:
    const { qLong, ...wLong } = { qLong: 7 };
    console.log(qLong, JSON.stringify(wLong));
}
export const { exLong, ...exRestLong } = { exLong: 8, y: 9 };
console.log(exLong, JSON.stringify(exRestLong));
