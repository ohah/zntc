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
switch (1) {
  case 1: {
    using a = R(1, log);
    log.push('c');
  }
}
console.log(log.join());
