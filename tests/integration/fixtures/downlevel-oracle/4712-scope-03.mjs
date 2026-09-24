const log = [];
function* gLong() {
  for (let iLong = 0; iLong < 2; iLong++) {
    try {
      throw iLong;
    } catch (eLong) {
      yield 0;
      log.push(() => eLong);
    }
  }
}
for (const vLong of gLong());
console.log(log.map((fLong) => fLong()).join());
