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
async function fLong() {
  using aLong = RLong(1, log);
  await 0;
  log.push('aw');
}
fLong().then(() => console.log(log.join()));
