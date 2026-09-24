function* g() {
  const o = {
    __proto__: {
      m() {
        return 5;
      },
    },
    n() {
      return super.m();
    },
  };
  yield o.n();
}
console.log([...g()].join());
