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
  if (i === 0) continue;
  log.push('b' + i);
}
console.log(log.join());
