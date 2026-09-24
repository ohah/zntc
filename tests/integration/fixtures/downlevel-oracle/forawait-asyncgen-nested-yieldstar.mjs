async function* inner(nLong) {
  yield nLong;
  yield nLong + 1;
}
async function* gLong() {
  for await (const aLong of [10, 20]) {
    for await (const bLong of inner(aLong)) yield bLong;
    yield* inner(aLong * 10);
  }
}
(async () => {
  const out = [];
  for await (const vLong of gLong()) out.push(vLong);
  console.log(out.join());
})();
