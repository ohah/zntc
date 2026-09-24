const xLong = 'OUT';
const log = [];
function* gLong() {
  {
    let xLong2 = 'IN';
    yield 1;
    log.push(xLong2);
  }
  log.push(xLong);
}
for (const vLong of gLong());
console.log(log.join());
