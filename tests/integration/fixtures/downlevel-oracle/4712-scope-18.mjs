const log = [];
function* g() {
  try {
    yield 1;
    throw { a: 'A', b: ['B'] };
  } catch ({ a = 'D', b: [c] = ['C'] }) {
    yield 2;
    log.push(a, c);
  }
}
for (const x of g());
console.log(log.join());
