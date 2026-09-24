const eLong = 'OUT';
const log = [];
function* gLong() {
  try {
    yield 1;
    throw 'X';
  } catch (eLong2) {
    yield 2;
    log.push([1].map(() => eLong2)[0]);
    function hLong(eLong3) {
      return 'h' + eLong3;
    }
    log.push(hLong('p'));
  }
  log.push(eLong);
}
for (const xLong of gLong());
console.log(log.join());
