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
for (let i = 0; i < 2; i++) {
  using a = R(i, log);
  log.push(() => i);
}
console.log(log.map((x) => (typeof x === 'function' ? x() : x)).join());
