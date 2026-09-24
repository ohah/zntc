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
  {
    using aLong = RLong(1, log);
    throw new Error('x');
  }
} catch (eLong) {
  log.push(eLong.message);
}
console.log(log.join());
