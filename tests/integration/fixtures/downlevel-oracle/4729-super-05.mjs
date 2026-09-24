const o = {
  __proto__: {
    m() {
      return 'a';
    },
  },
  n() {
    return super.m();
  },
};
Object.setPrototypeOf(o, {
  m() {
    return 'b';
  },
});
console.log(o.n());
