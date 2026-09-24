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
  'use strict';
  using a = R(1, log);
  return typeof this;
}
log.push(f());
console.log(log.join());
