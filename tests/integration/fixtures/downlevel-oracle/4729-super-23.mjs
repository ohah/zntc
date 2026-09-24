const oLong = {
  __proto__: {
    get v() {
      return this.t;
    },
  },
  t: 3,
  get w() {
    return super.v;
  },
  set w(xLong) {
    super.t = xLong;
  },
};
oLong.w = 9;
console.log(oLong.w, oLong.t);
