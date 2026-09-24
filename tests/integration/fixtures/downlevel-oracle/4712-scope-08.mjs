const eLong = 'OUT';
const log = [];
function* gLong() {
  try {
    yield 1;
    throw 'X';
  } catch {
    yield 2;
    log.push(eLong);
  }
}
for (const vLong of gLong());
console.log(log.join());
