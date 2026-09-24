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
    yield vLong2;
    if (vLong2 === 1) throw new Error('x');
  }
}
try {
  for (const xLong of gLong()) log.push(xLong);
} catch (eLong) {
  log.push(eLong.message);
}
console.log(log.join());
