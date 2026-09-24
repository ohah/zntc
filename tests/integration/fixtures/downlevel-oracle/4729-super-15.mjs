const oLong = {
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
console.log(oLong.n());
