const fns = [];
(async () => {
  for await (const vLong of [1, 2]) {
    await 0;
    fns.push(() => vLong);
  }
  console.log(fns.map((fLong) => fLong()).join());
})();
