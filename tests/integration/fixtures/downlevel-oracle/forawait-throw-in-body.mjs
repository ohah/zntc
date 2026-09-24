const log = [];
async function* src(n, opts) {
  try {
    for (let i = 0; i < n; i++) {
      if (opts.throwAt === i) throw new Error('src' + i);
      yield i;
    }
  } finally {
    log.push('srcfin');
  }
}
(async () => {
  try {
    for await (const v of src(3, {})) {
      if (v === 1) throw new Error('b');
    }
  } catch (e) {
    log.push(e.message);
  }
  console.log(log.join());
})();
