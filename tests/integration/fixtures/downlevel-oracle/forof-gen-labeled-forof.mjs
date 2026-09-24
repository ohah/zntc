function* gLong() {
  a: for (const xLong of [1, 2, 3]) {
    for (const yLong of [1, 2]) {
      if (yLong === 2) continue a;
      if (xLong === 3) break a;
      yield xLong + '' + yLong;
    }
  }
  yield 'end';
}
console.log([...gLong()].join());
