const pLong = {};
const oLong = {
  __proto__: pLong,
  s(vLong) {
    super.y = vLong;
    return this.y;
  },
};
console.log(oLong.s(3), Object.hasOwn(oLong, 'y'), pLong.y);
