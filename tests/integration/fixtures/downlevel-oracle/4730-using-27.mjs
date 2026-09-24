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
out: for (const k of [1, 2]) {
  for (using x of [R(k * 10 + 1, log), R(k * 10 + 2, log)]) {
    if (k === 1) continue out;
    log.push('b' + k);
  }
}
console.log(log.join());
