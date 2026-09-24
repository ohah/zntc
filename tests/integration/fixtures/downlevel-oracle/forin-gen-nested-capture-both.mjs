const fns = [];
function* g() {
  for (const a in { x: 1, y: 2 })
    for (const b in { p: 1, q: 2 }) {
      yield 0;
      fns.push(() => a + b);
    }
}
for (const _ of g());
console.log(fns.map((f) => f()).join());
