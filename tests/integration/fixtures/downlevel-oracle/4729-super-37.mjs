const o = {
  __proto__: {
    m() {
      return 'p';
    },
  },
  n() {
    return super.m();
  },
};
const { n } = o;
console.log(n.call(o), typeof (0, o).n);
