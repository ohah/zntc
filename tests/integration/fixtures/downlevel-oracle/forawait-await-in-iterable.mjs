(async () => {
  const out = [];
  for await (const v of await Promise.resolve([4, 5])) out.push(v);
  console.log(out.join());
})();
