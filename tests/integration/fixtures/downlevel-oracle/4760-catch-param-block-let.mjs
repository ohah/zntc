// catch 파라미터와 같은 이름의 블록 let
function f() {
  const r = [];
  try {
    throw 'err';
  } catch (e) {
    {
      let e = 'block';
      r.push(e);
    }
    r.push(e);
  }
  return r.join();
}
console.log(f());
