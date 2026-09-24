const o = {
  __proto__: {
    m() {
      return 1;
    },
  },
  ['k' + 1]() {
    return super.m();
  },
};
console.log(o.k1());
