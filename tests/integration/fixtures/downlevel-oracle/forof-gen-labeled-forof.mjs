function* g() {
  a: for (const x of [1, 2, 3]) {
    for (const y of [1, 2]) {
      if (y === 2) continue a;
      if (x === 3) break a;
      yield x + '' + y;
    }
  }
  yield 'end';
}
console.log([...g()].join());
