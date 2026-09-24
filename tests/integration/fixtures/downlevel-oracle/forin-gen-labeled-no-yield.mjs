function* gLong() {
  const out = [];
  a: for (const kLong in { x: 1, y: 2, z: 3 }) {
    for (const jLong in { p: 1, q: 2 }) {
      if (jLong === 'q') continue a;
      if (kLong === 'z') break a;
      out.push(kLong + jLong);
    }
  }
  yield out.join();
}
console.log([...gLong()].join());
