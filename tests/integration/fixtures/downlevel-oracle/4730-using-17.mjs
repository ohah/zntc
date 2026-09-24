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
  try {
    {
      using aLong = RLong(iLong, log);
      if (iLong === 0) throw new Error('e');
      log.push('ok' + iLong);
    }
  } catch (eLong) {
    log.push('c' + iLong);
  }
}
console.log(log.join());
