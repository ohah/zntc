const R = (n, log) => ({
  [Symbol.dispose]() {
    log.push('d' + n);
  },
});
const AR = (n, log) => ({
  async [Symbol.asyncDispose]() {
    log.push('ad' + n);
  },
});
const log = [];
(async () => {
  async function* src() {
    yield R(1, log);
    yield R(2, log);
  }
  for await (using x of src()) {
    await 0;
    log.push('b');
  }
  console.log(log.join());
})();
