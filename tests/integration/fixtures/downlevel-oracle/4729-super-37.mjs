const oLong = {
  __proto__: {
    m() {
      return 'p';
    },
  },
  n() {
    return super.m();
  },
};
const { n: nLong } = oLong;
console.log(nLong.call(oLong), typeof (0, oLong).n);
