async function* gLong() {
  a: for await (const xLong of [1, 2, 3]) {
    for await (const yLong of [1, 2]) {
      if (yLong === 2) continue a;
      if (xLong === 3) break a;
      yield xLong + '' + yLong;
    }
  }
  yield 'end';
}
(async () => {
  const out = [];
  for await (const vLong of gLong()) out.push(vLong);
  console.log(out.join());
})();
