const log = [];
function* gLong() {
  let xLong = 'top';
  {
    let xLong2 = 'inner';
    yield 1;
    log.push(xLong2);
  }
  log.push(xLong);
}
for (const vLong of gLong());
console.log(log.join());
