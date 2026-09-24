(async () => {
  const out = [];
  for await (const aLong of [1, 2]) {
    for (const bLong of ['x']) out.push(aLong + bLong);
    for (const kLong in { p: 1 }) {
      await 0;
      out.push(aLong + kLong);
    }
  }
  console.log(out.join());
})();
