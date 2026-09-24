function* inner(nLong) {
  yield nLong;
  yield nLong + 1;
  return 'r' + nLong;
}
function* gLong() {
  for (const nLong2 of [10, 20]) {
    const rLong = yield* inner(nLong2);
    yield rLong;
  }
}
console.log([...gLong()].join());
