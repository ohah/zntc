const out = [];
(async () => {
  for (const k in { a: 1, b: 2 }) {
    await 0;
    out.push(k);
  }
  console.log(out.join());
})();
