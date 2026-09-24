const _obj = 5;
const oLong = {
  __proto__: {
    m() {
      return 1;
    },
  },
  a: _obj,
  async n() {
    return super.m();
  },
};
oLong.n().then((vLong) => console.log(oLong.a, vLong));
