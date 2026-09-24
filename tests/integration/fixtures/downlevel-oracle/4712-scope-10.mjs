const log = [];
function* gLong() {
  try {
    yield 1;
    throw 'A';
  } catch (eLong) {
    try {
      yield 2;
      throw 'B';
    } catch (eLong2) {
      yield 3;
      log.push(eLong2);
    }
    log.push(eLong);
  }
}
for (const vLong of gLong());
console.log(log.join());
