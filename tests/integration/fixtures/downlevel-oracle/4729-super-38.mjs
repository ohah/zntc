const o = {
  __proto__: {
    m() {
      return 'p';
    },
  },
  n() {
    return super.m();
  },
}['n'];
console.log(o.call({}));
