function* gLong() {
  const oLong = {
    __proto__: {
      m() {
        return 5;
      },
    },
    n() {
      return super.m();
    },
  };
  yield oLong.n();
}
console.log([...gLong()].join());
