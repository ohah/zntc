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
label: {
  using a = R(1, log);
  log.push('in');
  break label;
}
console.log(log.join());
