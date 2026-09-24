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
const fs = [];
for (let i = 0; i < 2; i++) {
  using a = R(i, log);
  fs.push(() => (a === undefined ? 'u' : 'ok'));
}
console.log(log.join(), fs.map((f) => f()).join());
