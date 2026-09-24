function* sg() {
  yield 'g1';
  yield 'g2';
}
const custom = {
  [Symbol.iterator]() {
    let i = 0;
    return {
      next: () => (i < 2 ? { value: 'c' + i++, done: false } : { value: undefined, done: true }),
    };
  },
};
function* outer() {
  for (const v of sg()) yield v;
  for (const v of new Set(['s1', 's2'])) yield v;
  for (const [k, x] of new Map([['k', 'v']])) yield k + x;
  for (const c of 'ab') yield c;
  for (const v of custom) yield v;
  for (const v of new Uint8Array([7, 8])) yield v;
  for (const v of [1, 2]) yield v;
}
console.log([...outer()].join());
