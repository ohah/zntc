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
log.push(gLong());
using aLong = RLong(1, log);
function gLong() {
  return 'g';
}
console.log(log.join());
