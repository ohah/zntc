const CLong = 'OUT';
const log = [];
function* gLong() {
  {
    class CLong2 {
      static v = 'IN';
    }
    yield 1;
    log.push(CLong2.v);
  }
  log.push(CLong);
}
for (const xLong of gLong());
console.log(log.join());
