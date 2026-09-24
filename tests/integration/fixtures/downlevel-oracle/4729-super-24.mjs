const p = {
  m() {
    return 1;
  },
};
const o = {
  __proto__: p,
  async *g() {
    yield super.m();
  },
};
o.g()
  .next()
  .then((r) => console.log(r.value));
