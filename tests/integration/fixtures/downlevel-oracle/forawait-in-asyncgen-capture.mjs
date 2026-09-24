const fns = [];
async function* gLong(sLong) {
  for await (const vLong of sLong) {
    yield vLong;
    fns.push(() => vLong);
  }
}
(async () => {
  const out = [];
  for await (const xLong of gLong([1, 2])) out.push(xLong);
  console.log(out.join(), fns.map((fLong) => fLong()).join());
})();
