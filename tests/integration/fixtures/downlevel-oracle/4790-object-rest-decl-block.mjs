// 객체 rest 선언을 낮춰도 블록 안 let/const 는 블록 밖으로 새면 안 된다 (#4790)
const out = [];
{
  const { alphaLong, ...restLong } = { alphaLong: 1, b: 2 };
  out.push(alphaLong, Object.keys(restLong).join());
}
{
  let { alphaLong, ...restLong } = { alphaLong: 3, c: 4 };
  out.push(alphaLong, Object.keys(restLong).join());
}
function probe() {
  if (true) {
    const { xLong, ...yLong } = { xLong: 5 };
    out.push(xLong, Object.keys(yLong).length);
  }
  return typeof xLong;
}
out.push(probe());
let alphaLong = 'outer',
  restLong = 'outer';
out.push(alphaLong, restLong);
console.log(out.join(','));
