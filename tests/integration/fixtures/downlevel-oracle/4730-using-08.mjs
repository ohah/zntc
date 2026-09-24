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
function fLong() {
  {
    using aLong = RLong(1, log);
    return 'r';
  }
}
log.push(fLong());
console.log(log.join());
