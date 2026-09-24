const pLong = {
  m() {
    return 'p:' + this.t;
  },
};
const oLong = {
  __proto__: pLong,
  t: 1,
  n() {
    return super.m();
  },
};
console.log(oLong.n());
