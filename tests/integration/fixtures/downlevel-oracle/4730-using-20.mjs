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
{
  using a = R(1, log);
  var _stack = 'user';
  log.push(_stack);
}
console.log(log.join());
