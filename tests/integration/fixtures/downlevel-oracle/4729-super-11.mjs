function mk(v) {
  return {
    __proto__: {
      m() {
        return v;
      },
    },
    n() {
      return super.m();
    },
  };
}
const a = mk(1),
  b = mk(2);
console.log(a.n(), b.n());
