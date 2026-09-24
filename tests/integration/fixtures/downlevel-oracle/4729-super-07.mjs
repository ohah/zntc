const o = {
  __proto__: {
    m() {
      return 1;
    },
  },
  async n() {
    return super.m();
  },
};
o.n().then((v) => console.log(v));
