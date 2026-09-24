// for-in/of 헤더 const + 바깥 같은 이름을 루프 뒤에 읽기
function f(k) {
  for (const k of ['a', 'b']) g(k);
  for (const k in { x: 1 }) g(k);
  return k;
}
const got = [];
function g(v) {
  got.push(v);
}
console.log(f('param'), got.join());
