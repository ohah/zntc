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
(async () => {
  for await (const vLong of src(3, {})) log.push(vLong);
  console.log(log.join());
})();
