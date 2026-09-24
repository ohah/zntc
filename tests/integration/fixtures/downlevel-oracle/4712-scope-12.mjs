const iLong = 'OUT';
const log = [];
function* gLong() {
  for (let iLong2 = 0; iLong2 < 1; iLong2++) {
    yield iLong2;
  }
  log.push(iLong);
}
for (const xLong of gLong());
console.log(log.join());
