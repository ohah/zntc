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
(async () => {
  {
    await using aLong = AR(1, log);
    using bLong = RLong(2, log);
    log.push('body');
  }
  console.log(log.join());
})();
