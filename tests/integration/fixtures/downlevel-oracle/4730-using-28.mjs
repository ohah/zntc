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
  for (await using xLong of [AR(1, log), AR(2, log)]) log.push('b');
  console.log(log.join());
})();
