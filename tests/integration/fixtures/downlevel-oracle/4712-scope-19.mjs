const message = 'OUT';
const log = [];
function* g(e) {
  {
    let { message } = e;
    yield 1;
    log.push(message);
  }
  log.push(message);
}
for (const v of g({ message: 'M' }));
console.log(log.join());
