const fns = [];
(async () => {
  for await (const aLong of [1, 2])
    for await (const bLong of ['x', 'y']) fns.push(() => aLong + bLong);
  console.log(fns.map((fLong) => fLong()).join());
})();
