const fLong = [];
(async () => {
  for (const xLong of [1, 2]) {
    await 0;
    fLong.push(() => xLong);
  }
  console.log(fLong.map((hLong) => hLong()).join());
})();
