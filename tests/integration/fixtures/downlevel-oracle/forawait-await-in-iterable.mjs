(async () => {
  const out = [];
  for await (const vLong of await Promise.resolve([4, 5])) out.push(vLong);
  console.log(out.join());
})();
