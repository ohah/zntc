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
for (const x of [1, 2]) {
  using a = R(x, log);
  if (x === 1) break;
}
console.log(log.join());
