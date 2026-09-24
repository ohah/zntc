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
out: for (const kLong of [1, 2]) {
  for (using xLong of [RLong(kLong * 10 + 1, log), RLong(kLong * 10 + 2, log)]) {
    if (kLong === 1) continue out;
    log.push('b' + kLong);
  }
}
console.log(log.join());
