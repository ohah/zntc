const err = 'OUTER';
const log = [];
function* gLong() {
  try {
    throw new Error('A');
  } catch (err) {
    log.push(err.message);
  }
  yield 1;
  log.push(err);
}
for (const vLong of gLong());
console.log(log.join());
