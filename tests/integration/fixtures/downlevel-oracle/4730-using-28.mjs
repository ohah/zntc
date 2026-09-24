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
  for (await using x of [AR(1, log), AR(2, log)]) log.push('b');
  console.log(log.join());
})();
