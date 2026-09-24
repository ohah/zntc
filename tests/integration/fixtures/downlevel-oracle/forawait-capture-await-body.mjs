const fns = [];
(async () => {
  for await (const v of [1, 2]) {
    await 0;
    fns.push(() => v);
  }
  console.log(fns.map((f) => f()).join());
})();
