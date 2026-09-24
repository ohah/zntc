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
{
  using aLong = RLong(1, log);
  var _stack = 'user';
  log.push(_stack);
}
console.log(log.join());
