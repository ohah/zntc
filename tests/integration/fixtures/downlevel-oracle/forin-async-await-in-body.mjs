const out = [];
(async () => {
  for (const kLong in { a: 1, b: 2 }) {
    await 0;
    out.push(kLong);
  }
  console.log(out.join());
})();
