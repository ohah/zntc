// 매개변수와 같은 이름의 루프 헤더 let + 클로저 캡처(_loop 추출)
function f(i, fns) {
  for (let i = 0; i < 3; i++) fns.push(() => i);
  return i;
}
const fns = [];
const r = f('param', fns);
console.log(r, fns.map((g) => g()).join());
