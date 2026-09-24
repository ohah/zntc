const o = {
  __proto__: {
    m() {
      return 1;
    },
  },
  ...{ a: 1 },
  n() {
    return super.m();
  },
};
console.log(o.n(), o.a);
