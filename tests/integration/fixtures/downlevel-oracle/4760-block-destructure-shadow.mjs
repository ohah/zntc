// 블록 안 구조분해가 바깥 같은 이름과 충돌
function f(a, obj) {
  {
    let {
      a,
      b: [c],
    } = obj;
    g(a, c);
  }
  return a;
}
const got = [];
function g(...v) {
  got.push(v.join('/'));
}
console.log(f('outer', { a: 'inner', b: ['C'] }), got.join());
