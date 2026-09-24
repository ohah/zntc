const log = [];
const AR = (nLong) => ({
  async [Symbol.asyncDispose]() {
    log.push('ad' + nLong);
  },
});
(async () => {
  for await (await using xLong of [AR(1), AR(2)]) log.push('b');
  console.log(log.join());
})();
