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
  for (using x of [R(1, log), R(2, log)]) {
    throw new Error('t');
  }
} catch (e) {
  log.push(e.message);
}
console.log(log.join());
