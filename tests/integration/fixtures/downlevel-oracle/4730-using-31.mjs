const RLong = (nLong, log) => ({
  [Symbol.dispose]() {
    log.push('d' + nLong);
  },
});
const AR = (nLong2, log) => ({
  async [Symbol.asyncDispose]() {
    log.push('ad' + nLong2);
  },
});
const log = [];
const fs = [];
for (using xLong of [RLong(1, log), RLong(2, log)]) fs.push(() => xLong !== undefined);
console.log(log.join(), fs.map((fLong) => fLong()).join());
