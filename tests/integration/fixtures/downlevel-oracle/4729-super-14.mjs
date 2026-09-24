const oLong = {
  __proto__: { v: 1 },
  n() {
    return super.v?.toFixed(1);
  },
};
console.log(oLong.n());
