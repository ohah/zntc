// eval 이 블록 바인딩 이름을 문자열로 읽는다
function f() {
  var x = 'v';
  {
    let x = 'b';
    return eval('x');
  }
}
console.log(f());
