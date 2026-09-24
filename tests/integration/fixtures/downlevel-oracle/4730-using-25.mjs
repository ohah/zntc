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
function f() {
  log.push(g());
  using a = R(1, log);
  const k = 1;
  function g() {
    return 'g' + typeof k;
  }
  return g();
}
try {
  log.push(f());
} catch (e) {
  log.push(e.constructor.name);
}
console.log(log.join());
