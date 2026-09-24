const o = {
  async *m(s) {
    for await (const v of s) yield v + 1;
  },
};
class C {
  async *n(s) {
    for await (const v of s) yield v * 3;
  }
}
const f = async (s) => {
  const r = [];
  for await (const v of s) r.push(v);
  return r;
};
(async () => {
  const out = [];
  for await (const v of o.m([1, 2])) out.push(v);
  for await (const v of new C().n([1])) out.push(v);
  out.push((await f([7, 8])).join(''));
  console.log(out.join());
})();
