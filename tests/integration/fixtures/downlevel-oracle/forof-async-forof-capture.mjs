const f = [];
(async () => {
  for (const x of [1, 2]) {
    await 0;
    f.push(() => x);
  }
  console.log(f.map((h) => h()).join());
})();
