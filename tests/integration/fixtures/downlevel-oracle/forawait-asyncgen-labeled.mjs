async function* g() {
  a: for await (const x of [1, 2, 3]) {
    for await (const y of [1, 2]) {
      if (y === 2) continue a;
      if (x === 3) break a;
      yield x + '' + y;
    }
  }
  yield 'end';
}
(async () => {
  const out = [];
  for await (const v of g()) out.push(v);
  console.log(out.join());
})();
