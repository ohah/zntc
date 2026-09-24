const oLong = {
  __proto__: {
    m() {
      return 'a';
    },
  },
  n() {
    return super.m();
  },
};
Object.setPrototypeOf(oLong, {
  m() {
    return 'b';
  },
});
console.log(oLong.n());
