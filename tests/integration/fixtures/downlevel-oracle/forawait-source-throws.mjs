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
  try {
    for await (const vLong of src(3, { throwAt: 1 })) log.push(vLong);
  } catch (eLong) {
    log.push(eLong.message);
  }
  console.log(log.join());
})();
