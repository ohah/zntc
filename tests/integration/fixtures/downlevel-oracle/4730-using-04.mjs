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
try {
  {
    using a = R(1, log);
    throw new Error('x');
  }
} catch (e) {
  log.push(e.message);
}
console.log(log.join());
