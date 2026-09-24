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
  {
    using a = R(1, log);
    return 'r';
  }
}
log.push(f());
console.log(log.join());
