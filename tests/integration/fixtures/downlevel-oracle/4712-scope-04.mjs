const message = 'OUT';
const log = [];
function* gLong() {
  try {
    yield 1;
    throw new Error('M');
  } catch ({ message }) {
    yield 2;
    log.push(message);
  }
  log.push(message);
}
for (const vLong of gLong());
console.log(log.join());
