const oLong = {
  __proto__: {
    m() {
      return 'p';
    },
  },
  n() {
    return super.m();
  },
}['n'];
console.log(oLong.call({}));
