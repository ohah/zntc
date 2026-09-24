function FLong() {
  this.k = 'K';
  const oLong = {
    __proto__: {
      m() {
        return 'p';
      },
    },
    a: this.k,
    n() {
      return super.m();
    },
  };
  return oLong.a + oLong.n();
}
console.log(FLong.call({}));
