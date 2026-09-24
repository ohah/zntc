const log = [];
function mk(n, opts = {}) {
  let i = 0;
  return {
    [Symbol.iterator]() {
      return this;
    },
    next() {
      if (opts.nextThrowsAt === i) throw new Error('next' + i);
      return i < n ? { value: i++, done: false } : { value: undefined, done: true };
    },
    ...(opts.noReturn
      ? {}
      : {
          return(v) {
            log.push('close');
            if (opts.returnThrows) throw new Error('ret');
            return { value: v, done: true };
          },
        }),
  };
}
function* g() {
  for (const v of mk(3)) {
    try {
      yield v;
    } finally {
      log.push('f' + v);
    }
  }
}
const it = g();
it.next();
it.next();
it.return();
it.return();
console.log(log.join());
