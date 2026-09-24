function* g() {
  for (const v of [1, 2, 3, 4]) {
    if (v === 2) continue;
    if (v === 4) break;
    yield v;
  }
  for (const v of [5, 6]) {
    for (const w of [7, 8]) {
      if (w === 8) continue;
      yield v * 10 + w;
    }
  }
}
console.log([...g()].join());
