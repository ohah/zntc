const log = [];
async function* src(nLong, opts) {
  try {
    for (let iLong = 0; iLong < nLong; iLong++) {
      if (opts.throwAt === iLong) throw new Error('src' + iLong);
      yield iLong;
    }
  } finally {
    log.push('srcfin');
  }
}
async function fLong() {
  for await (const vLong of src(3, {})) {
    if (vLong === 1) return 'r';
    log.push(vLong);
  }
}
fLong().then((rLong) => {
  log.push(rLong);
  console.log(log.join());
});
