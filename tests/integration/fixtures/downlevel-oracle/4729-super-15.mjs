const o = {
  __proto__: {
    m() {
      return this.t;
    },
  },
  t: 7,
  n() {
    return super['m']();
  },
};
console.log(o.n());
