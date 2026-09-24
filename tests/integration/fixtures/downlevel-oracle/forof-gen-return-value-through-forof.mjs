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
    if (v === 2) return 'ret' + v;
    yield v;
  }
}
const it = g();
const out = [];
let r;
while (!(r = it.next()).done) out.push(r.value);
console.log(out.join(), r.value, log.join());
