const err = 'OUTER';
const log = [];
function* gLong() {
  try {
    yield 1;
    throw new Error('A');
  } catch (err) {
    err = new Error('B');
    yield 'rec';
  }
  log.push('outer ' + err);
}
for (const vLong of gLong());
console.log(log.join());
