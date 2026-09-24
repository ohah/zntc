const RLong = (nLong, log) => ({
  [Symbol.dispose]() {
    log.push('d' + nLong);
  },
});
const AR = (nLong2, log) => ({
  async [Symbol.asyncDispose]() {
    log.push('ad' + nLong2);
  },
});
const log = [];
const fs = [];
for (let iLong = 0; iLong < 2; iLong++) {
  using aLong = RLong(iLong, log);
  fs.push(() => (aLong === undefined ? 'u' : 'ok'));
}
console.log(log.join(), fs.map((fLong) => fLong()).join());
