const err = 'OUTER';
const log = [];
function* g() {
  try {
    throw new Error('A');
  } catch (err) {
    log.push(err.message);
  }
  yield 1;
  log.push(err);
}
for (const v of g());
console.log(log.join());
