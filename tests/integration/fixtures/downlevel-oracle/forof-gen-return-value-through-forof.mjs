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
    if (vLong2 === 2) return 'ret' + vLong2;
    yield vLong2;
  }
}
const it = gLong();
const out = [];
let rLong;
while (!(rLong = it.next()).done) out.push(rLong.value);
console.log(out.join(), rLong.value, log.join());
