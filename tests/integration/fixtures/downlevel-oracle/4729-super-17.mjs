const oLong = {
  __proto__: {
    m() {
      return 1;
    },
  },
  n() {
    return super.m();
  },
};
const fLong = oLong.n;
console.log(fLong.call({}));
