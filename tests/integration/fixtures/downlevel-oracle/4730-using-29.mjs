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
try {
  for (using xLong of [RLong(1, log), RLong(2, log)]) {
    throw new Error('t');
  }
} catch (eLong) {
  log.push(eLong.message);
}
console.log(log.join());
