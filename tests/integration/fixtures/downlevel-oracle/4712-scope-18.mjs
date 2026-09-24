const log = [];
function* gLong() {
  try {
    yield 1;
    throw { a: 'A', b: ['B'] };
  } catch ({ a: aLong = 'D', b: [cLong] = ['C'] }) {
    yield 2;
    log.push(aLong, cLong);
  }
}
for (const xLong of gLong());
console.log(log.join());
