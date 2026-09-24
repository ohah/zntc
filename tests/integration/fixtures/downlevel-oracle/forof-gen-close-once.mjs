const log = [];
function mk(nLong, opts = {}) {
  let iLong = 0;
  return {
    [Symbol.iterator]() {
      return this;
    },
    next() {
      if (opts.nextThrowsAt === iLong) throw new Error('next' + iLong);
      return iLong < nLong ? { value: iLong++, done: false } : { value: undefined, done: true };
    },
    ...(opts.noReturn
      ? {}
      : {
          return(vLong) {
            log.push('close');
            if (opts.returnThrows) throw new Error('ret');
            return { value: vLong, done: true };
          },
        }),
  };
}
function* gLong() {
  for (const vLong2 of mk(3)) {
    try {
      yield vLong2;
    } finally {
      log.push('f' + vLong2);
    }
  }
}
const it = gLong();
it.next();
it.next();
it.return();
it.return();
console.log(log.join());
