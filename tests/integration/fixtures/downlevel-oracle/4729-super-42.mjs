const _obj = 5;
const o = {
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
o.n().then((v) => console.log(o.a, v));
