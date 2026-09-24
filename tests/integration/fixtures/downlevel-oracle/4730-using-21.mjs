const R = (n, log) => ({
  [Symbol.dispose]() {
    log.push('d' + n);
  },
});
const AR = (n, log) => ({
  async [Symbol.asyncDispose]() {
    log.push('ad' + n);
  },
});
const log = [];
function* g() {
  using a = R(1, log);
  yield 1;
  log.push('after');
}
const it = g();
it.next();
it.return();
console.log(log.join());
