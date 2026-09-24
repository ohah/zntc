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
for (const xLong of [1, 2]) {
  using aLong = RLong(xLong, log);
  if (xLong === 1) break;
}
console.log(log.join());
