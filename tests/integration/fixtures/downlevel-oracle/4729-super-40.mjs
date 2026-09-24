const k = 'x';
const o = {
  __proto__: {
    x() {
      return 'px';
    },
  },
  [k]() {
    return super[k]();
  },
  get [k + 'g']() {
    return super.x();
  },
};
console.log(o.x(), o.xg);
