(async () => {
  const out = [];
  for await (const [a, { b = 9 }] of [
    [1, {}],
    [2, { b: 3 }],
  ])
    out.push(a + b);
  for await (const { x, ...r } of [{ x: 1, y: 2 }]) out.push(x + Object.keys(r).join(''));
  console.log(out.join());
})();
