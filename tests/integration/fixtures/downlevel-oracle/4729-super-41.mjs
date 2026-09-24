class XLong {
  q() {
    return 'X';
  }
}
const oLong = {
  __proto__: {
    k: 'P',
    q() {
      return 'Pq';
    },
  },
  async n() {
    class CLong extends XLong {
      [super.k]() {
        return 'm';
      }
    }
    return Object.getOwnPropertyNames(CLong.prototype).join(',');
  },
};
oLong.n().then((vLong) => console.log(vLong));
