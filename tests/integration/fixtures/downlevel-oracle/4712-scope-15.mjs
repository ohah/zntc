const a = 'OUT';
const log = [];
function* g() {
  try {
    yield 1;
    throw {};
  } catch ({ a = 'D', b: [c] = ['C'] }) {
    yield 2;
    log.push(a, c);
  }
  log.push(a);
}
for (const x of g());
console.log(log.join());
