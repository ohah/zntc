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
function* gLong() {
  using aLong = RLong(1, log);
  yield 1;
  log.push('after');
}
const it = gLong();
it.next();
it.return();
console.log(log.join());
