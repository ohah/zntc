class X {
  q() {
    return 'X';
  }
}
const o = {
  __proto__: {
    k: 'P',
    q() {
      return 'Pq';
    },
  },
  async n() {
    class C extends X {
      [super.k]() {
        return 'm';
      }
    }
    return Object.getOwnPropertyNames(C.prototype).join(',');
  },
};
o.n().then((v) => console.log(v));
