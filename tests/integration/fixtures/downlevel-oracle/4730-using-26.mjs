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
function* gLong() {
  for (using xLong of [RLong(1, log), RLong(2, log)]) {
    yield 1;
    log.push('y');
  }
}
for (const vLong of gLong()) log.push('v');
console.log(log.join());
