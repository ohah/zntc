const message = 'OUT';
const log = [];
function* g() {
  try {
    yield 1;
    throw new Error('M');
  } catch ({ message }) {
    yield 2;
    log.push(message);
  }
  log.push(message);
}
for (const v of g());
console.log(log.join());
