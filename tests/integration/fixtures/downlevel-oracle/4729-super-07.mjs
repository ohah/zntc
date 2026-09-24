const oLong = {
  __proto__: {
    m() {
      return 1;
    },
  },
  async n() {
    return super.m();
  },
};
oLong.n().then((vLong) => console.log(vLong));
