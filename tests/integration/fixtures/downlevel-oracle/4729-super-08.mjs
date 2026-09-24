const oLong = {
  __proto__: {
    m() {
      return 1;
    },
  },
  *n() {
    yield super.m();
  },
};
console.log([...oLong.n()]);
