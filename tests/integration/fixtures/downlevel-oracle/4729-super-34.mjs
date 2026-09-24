const mk = (pLong) => ({
  __proto__: pLong,
  n() {
    return super.m();
  },
});
const aLong = mk({
    m() {
      return 1;
    },
  }),
  bLong = mk({
    m() {
      return 2;
    },
  });
console.log(aLong.n(), bLong.n());
