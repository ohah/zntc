const fns = [];
(async () => {
  for await (const v of [1, 2]) fns.push(() => v);
  console.log(fns.map((f) => f()).join());
})();
