const log = [];
const AR = (n) => ({
  async [Symbol.asyncDispose]() {
    log.push('ad' + n);
  },
});
(async () => {
  for await (await using x of [AR(1), AR(2)]) log.push('b');
  console.log(log.join());
})();
