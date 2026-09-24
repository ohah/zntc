const mk = (p) => ({
  __proto__: p,
  n() {
    return super.m();
  },
});
const a = mk({
    m() {
      return 1;
    },
  }),
  b = mk({
    m() {
      return 2;
    },
  });
console.log(a.n(), b.n());
