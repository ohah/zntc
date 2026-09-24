(async () => {
  const out = [];
  for await (const v of [1]) {
    let v = 'in';
    out.push(v);
  }
  console.log(out.join());
})();
