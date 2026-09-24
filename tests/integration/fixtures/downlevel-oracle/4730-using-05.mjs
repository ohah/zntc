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
for (let iLong = 0; iLong < 2; iLong++) {
  using aLong = RLong(iLong, log);
  if (iLong === 0) continue;
  log.push('b' + iLong);
}
console.log(log.join());
