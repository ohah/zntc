const kLong = 'x';
const oLong = {
  __proto__: {
    x() {
      return 'px';
    },
  },
  [kLong]() {
    return super[kLong]();
  },
  get [kLong + 'g']() {
    return super.x();
  },
};
console.log(oLong.x(), oLong.xg);
