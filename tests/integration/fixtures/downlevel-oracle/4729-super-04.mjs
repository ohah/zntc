const pLong = {
  m() {
    return 1;
  },
};
const oLong = {
  __proto__: pLong,
  n() {
    return [1].map(() => super.m());
  },
};
console.log(oLong.n());
