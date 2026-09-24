// switch case 의 let 을 es5 var 로 낮출 때 바깥 같은 이름을 덮으면 안 된다 (#4764).
const value = 'outer';
const out = [];
function run(kind) {
  switch (kind) {
    case 0:
      let value = 'zero';
      out.push(value);
      break;
    default:
      out.push('other');
  }
  out.push(value);
}
run(0);
run(1);
console.log(out.join());
