const fns = [];
function* gLong() {
  for (const aLong in { x: 1, y: 2 })
    for (const bLong in { p: 1, q: 2 }) {
      yield 0;
      fns.push(() => aLong + bLong);
    }
}
for (const _Long of gLong());
console.log(fns.map((fLong) => fLong()).join());
