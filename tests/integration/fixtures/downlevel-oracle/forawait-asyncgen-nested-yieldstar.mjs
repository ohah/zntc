async function* inner(n) {
  yield n;
  yield n + 1;
}
async function* g() {
  for await (const a of [10, 20]) {
    for await (const b of inner(a)) yield b;
    yield* inner(a * 10);
  }
}
(async () => {
  const out = [];
  for await (const v of g()) out.push(v);
  console.log(out.join());
})();
