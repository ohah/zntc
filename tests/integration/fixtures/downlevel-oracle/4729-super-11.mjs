function mk(vLong) {
  return {
    __proto__: {
      m() {
        return vLong;
      },
    },
    n() {
      return super.m();
    },
  };
}
const aLong = mk(1),
  bLong = mk(2);
console.log(aLong.n(), bLong.n());
