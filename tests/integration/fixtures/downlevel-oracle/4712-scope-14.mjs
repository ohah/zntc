const C = 'OUT';
const log = [];
function* g() {
  {
    class C {
      static v = 'IN';
    }
    yield 1;
    log.push(C.v);
  }
  log.push(C);
}
for (const x of g());
console.log(log.join());
