async function* gLong(sLong) {
  for await (const vLong of sLong) yield vLong * 2;
}
(async () => {
  const out = [];
  for await (const xLong of gLong([1, Promise.resolve(2)])) out.push(xLong);
  console.log(out.join());
})();
