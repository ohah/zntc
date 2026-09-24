(async () => {
  const out = [];
  for await (const a of [1, 2]) {
    for (const b of ['x']) out.push(a + b);
    for (const k in { p: 1 }) {
      await 0;
      out.push(a + k);
    }
  }
  console.log(out.join());
})();
