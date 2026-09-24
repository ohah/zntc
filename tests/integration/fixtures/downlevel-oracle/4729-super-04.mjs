const p = {
  m() {
    return 1;
  },
};
const o = {
  __proto__: p,
  n() {
    return [1].map(() => super.m());
  },
};
console.log(o.n());
