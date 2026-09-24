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
  for await (const v of src(3, {})) log.push(v);
  console.log(log.join());
})();
