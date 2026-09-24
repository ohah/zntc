// 함수 본문 var 와 같은 이름의 블록 let 을 합치면 바깥 변수를 덮는다 (#4758).
function counter() {
  var total = 0;
  {
    let total = 100;
    total += 1;
  }
  return total;
}
console.log(counter());
