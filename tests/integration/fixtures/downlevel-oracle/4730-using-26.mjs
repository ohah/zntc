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
  for (using x of [R(1, log), R(2, log)]) {
    yield 1;
    log.push('y');
  }
}
for (const v of g()) log.push('v');
console.log(log.join());
