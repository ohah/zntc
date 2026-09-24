const o = {
  __proto__: {
    get v() {
      return this.t;
    },
  },
  t: 3,
  get w() {
    return super.v;
  },
  set w(x) {
    super.t = x;
  },
};
o.w = 9;
console.log(o.w, o.t);
