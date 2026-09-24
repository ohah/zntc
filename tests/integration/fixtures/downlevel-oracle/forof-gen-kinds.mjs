function* sg() {
  yield 'g1';
  yield 'g2';
}
const custom = {
  [Symbol.iterator]() {
    let iLong = 0;
    return {
      next: () =>
        iLong < 2 ? { value: 'c' + iLong++, done: false } : { value: undefined, done: true },
    };
  },
};
function* outer() {
  for (const vLong of sg()) yield vLong;
  for (const vLong2 of new Set(['s1', 's2'])) yield vLong2;
  for (const [kLong, xLong] of new Map([['k', 'v']])) yield kLong + xLong;
  for (const cLong of 'ab') yield cLong;
  for (const vLong3 of custom) yield vLong3;
  for (const vLong4 of new Uint8Array([7, 8])) yield vLong4;
  for (const vLong5 of [1, 2]) yield vLong5;
}
console.log([...outer()].join());
