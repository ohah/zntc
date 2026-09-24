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
  {
    using b = R(2, log);
    log.push('inner');
  }
  log.push('outer');
}
console.log(log.join());
