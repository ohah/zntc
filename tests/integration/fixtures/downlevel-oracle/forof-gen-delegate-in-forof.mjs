function* inner(n) {
  yield n;
  yield n + 1;
  return 'r' + n;
}
function* g() {
  for (const n of [10, 20]) {
    const r = yield* inner(n);
    yield r;
  }
}
console.log([...g()].join());
