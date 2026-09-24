(async () => {
  const out = [];
  for await (const [aLong, { b: bLong = 9 }] of [
    [1, {}],
    [2, { b: 3 }],
  ])
    out.push(aLong + bLong);
  for await (const { x: xLong, ...rLong } of [{ x: 1, y: 2 }])
    out.push(xLong + Object.keys(rLong).join(''));
  console.log(out.join());
})();
