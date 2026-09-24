function* g() {
  const out = [];
  a: for (const k in { x: 1, y: 2, z: 3 }) {
    for (const j in { p: 1, q: 2 }) {
      if (j === 'q') continue a;
      if (k === 'z') break a;
      yield k + j;
    }
  }
  yield 'end';
}
console.log([...g()].join());
