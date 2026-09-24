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
  {
    await using a = AR(1, log);
    using b = R(2, log);
    log.push('body');
  }
  console.log(log.join());
})();
