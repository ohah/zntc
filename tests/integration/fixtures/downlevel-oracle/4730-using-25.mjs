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
function fLong() {
  log.push(gLong());
  using aLong = RLong(1, log);
  const kLong = 1;
  function gLong() {
    return 'g' + typeof kLong;
  }
  return gLong();
}
try {
  log.push(fLong());
} catch (eLong) {
  log.push(eLong.constructor.name);
}
console.log(log.join());
