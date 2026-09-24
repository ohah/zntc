const fns = [];
(async () => {
  for await (const a of [1, 2]) for await (const b of ['x', 'y']) fns.push(() => a + b);
  console.log(fns.map((f) => f()).join());
})();
