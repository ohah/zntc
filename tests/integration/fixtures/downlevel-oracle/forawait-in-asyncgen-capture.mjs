const fns = [];
async function* g(s) {
  for await (const v of s) {
    yield v;
    fns.push(() => v);
  }
}
(async () => {
  const out = [];
  for await (const x of g([1, 2])) out.push(x);
  console.log(out.join(), fns.map((f) => f()).join());
})();
