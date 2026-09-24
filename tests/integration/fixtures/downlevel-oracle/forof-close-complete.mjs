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
for (const vLong2 of mk(2)) log.push(vLong2);
console.log(log.join());
