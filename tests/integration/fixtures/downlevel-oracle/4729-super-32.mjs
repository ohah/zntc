function F() {
  this.k = 'K';
  const o = {
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
  return o.a + o.n();
}
console.log(F.call({}));
