const e = 'OUT';
const log = [];
function* g() {
  try {
    yield 1;
    throw 'X';
  } catch (e) {
    yield 2;
    log.push([1].map(() => e)[0]);
    function h(e) {
      return 'h' + e;
    }
    log.push(h('p'));
  }
  log.push(e);
}
for (const x of g());
console.log(log.join());
