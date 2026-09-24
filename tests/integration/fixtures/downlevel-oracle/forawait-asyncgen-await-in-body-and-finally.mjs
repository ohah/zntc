const log = [];
async function* g(s) {
  for await (const v of s) {
    try {
      await 0;
      yield v;
    } finally {
      await 0;
      log.push('f' + v);
    }
  }
}
(async () => {
  for await (const v of g([1, 2])) log.push(v);
  console.log(log.join());
})();
