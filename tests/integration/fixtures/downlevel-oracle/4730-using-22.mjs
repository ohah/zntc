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
async function f() {
  using a = R(1, log);
  await 0;
  log.push('aw');
}
f().then(() => console.log(log.join()));
