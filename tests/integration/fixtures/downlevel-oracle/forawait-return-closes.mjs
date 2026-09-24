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
async function f() {
  for await (const v of src(3, {})) {
    if (v === 1) return 'r';
    log.push(v);
  }
}
f().then((r) => {
  log.push(r);
  console.log(log.join());
});
