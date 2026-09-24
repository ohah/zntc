const pLong = {
  m() {
    return 1;
  },
};
const oLong = {
  __proto__: pLong,
  async *g() {
    yield super.m();
  },
};
oLong
  .g()
  .next()
  .then((rLong) => console.log(rLong.value));
