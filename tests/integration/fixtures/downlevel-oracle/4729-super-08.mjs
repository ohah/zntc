const o = {
  __proto__: {
    m() {
      return 1;
    },
  },
  *n() {
    yield super.m();
  },
};
console.log([...o.n()]);
