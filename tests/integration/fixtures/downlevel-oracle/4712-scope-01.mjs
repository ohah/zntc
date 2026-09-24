const err = 'OUTER';
const log = [];
function* g() {
  try {
    yield 1;
    throw new Error('A');
  } catch (err) {
    err = new Error('B');
    yield 'rec';
  }
  log.push('outer ' + err);
}
for (const v of g());
console.log(log.join());
