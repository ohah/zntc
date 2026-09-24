const x = 'OUT';
const log = [];
function* g() {
  {
    let x = 'IN';
    yield 1;
    log.push(x);
  }
  log.push(x);
}
for (const v of g());
console.log(log.join());
