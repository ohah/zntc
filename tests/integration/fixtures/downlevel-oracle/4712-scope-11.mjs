const zLong = 'OUT';
const log = [];
function* gLong(vLong) {
  switch (vLong) {
    case 1: {
      let zLong2 = 'IN';
      yield 1;
      log.push(zLong2);
    }
  }
  log.push(zLong);
}
for (const xLong of gLong(1));
console.log(log.join());
