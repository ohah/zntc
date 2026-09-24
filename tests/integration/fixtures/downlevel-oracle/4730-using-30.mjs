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
  async function* src() {
    yield RLong(1, log);
    yield RLong(2, log);
  }
  for await (using xLong of src()) {
    await 0;
    log.push('b');
  }
  console.log(log.join());
})();
