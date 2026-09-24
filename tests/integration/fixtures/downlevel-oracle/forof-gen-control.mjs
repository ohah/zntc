function* gLong() {
  for (const vLong of [1, 2, 3, 4]) {
    if (vLong === 2) continue;
    if (vLong === 4) break;
    yield vLong;
  }
  for (const vLong2 of [5, 6]) {
    for (const wLong of [7, 8]) {
      if (wLong === 8) continue;
      yield vLong2 * 10 + wLong;
    }
  }
}
console.log([...gLong()].join());
