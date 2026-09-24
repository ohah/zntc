const oLong = {
  __proto__: {
    m() {
      return 1;
    },
  },
  ['k' + 1]() {
    return super.m();
  },
};
console.log(oLong.k1());
