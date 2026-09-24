const aLong = 'OUT';
const log = [];
function* gLong() {
  try {
    yield 1;
    throw {};
  } catch ({ a: aLong2 = 'D', b: [cLong] = ['C'] }) {
    yield 2;
    log.push(aLong2, cLong);
  }
  log.push(aLong);
}
for (const xLong of gLong());
console.log(log.join());
