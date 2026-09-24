// 블록 안 class 가 바깥 같은 이름을 덮으면 안 된다
class Box {
  who() {
    return 'outer';
  }
}
function f() {
  {
    class Box {
      who() {
        return 'inner';
      }
    }
    g(new Box().who());
  }
  return new Box().who();
}
const got = [];
function g(v) {
  got.push(v);
}
console.log(f(), got.join());
