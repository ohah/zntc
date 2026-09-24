const log = [];
async function* gLong(sLong) {
  for await (const vLong of sLong) {
    try {
      await 0;
      yield vLong;
    } finally {
      await 0;
      log.push('f' + vLong);
    }
  }
}
(async () => {
  for await (const vLong2 of gLong([1, 2])) log.push(vLong2);
  console.log(log.join());
})();
