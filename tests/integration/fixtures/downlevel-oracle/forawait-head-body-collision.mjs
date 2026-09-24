(async () => {
  const out = [];
  for await (const vLong of [1]) {
    let vLong2 = 'in';
    out.push(vLong2);
  }
  console.log(out.join());
})();
