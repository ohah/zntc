const p = {
  m() {
    return 'p:' + this.t;
  },
};
const o = {
  __proto__: p,
  t: 1,
  n() {
    return super.m();
  },
};
console.log(o.n());
