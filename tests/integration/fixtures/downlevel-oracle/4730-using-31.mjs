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
for (using x of [R(1, log), R(2, log)]) fs.push(() => x !== undefined);
console.log(log.join(), fs.map((f) => f()).join());
