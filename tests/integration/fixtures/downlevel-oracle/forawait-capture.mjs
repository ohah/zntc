const fns = [];
(async () => {
  for await (const vLong of [1, 2]) fns.push(() => vLong);
  console.log(fns.map((fLong) => fLong()).join());
})();
