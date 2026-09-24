// 형제 블록 한쪽이 클로저에 잡히고 다른 쪽이 대입
const fns = [];
function f() {
  {
    let x = 'A';
    fns.push(() => x);
  }
  {
    let x = 'B';
    x += '!';
  }
}
f();
console.log(fns[0]());
