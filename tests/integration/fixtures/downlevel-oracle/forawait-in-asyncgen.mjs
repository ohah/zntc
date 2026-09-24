async function* g(s) {
  for await (const v of s) yield v * 2;
}
(async () => {
  const out = [];
  for await (const x of g([1, Promise.resolve(2)])) out.push(x);
  console.log(out.join());
})();
