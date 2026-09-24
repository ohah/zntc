// 형제 블록 병합 + 초기값 없는 let: 두 번째 블록의 x 는 undefined 여야 한다
const out = [];
function f() {
  {
    let x = 1;
    out.push(x);
  }
  {
    let x;
    out.push(String(x));
  }
}
f();
console.log(out.join());
