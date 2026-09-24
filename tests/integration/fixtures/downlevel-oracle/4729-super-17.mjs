const o = {
  __proto__: {
    m() {
      return 1;
    },
  },
  n() {
    return super.m();
  },
};
const f = o.n;
console.log(f.call({}));
