const log = [];
function* gLong() {
  for (let iLong = 0; iLong < 2; iLong++) {
    const vLong = iLong * 10;
    yield 0;
    log.push(() => vLong);
  }
}
for (const _Long of gLong());
console.log(log.map((fLong) => fLong()).join());
