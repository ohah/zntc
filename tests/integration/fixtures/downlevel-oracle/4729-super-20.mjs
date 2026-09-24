class ALong {
  m() {
    return 'A';
  }
}
class BLong extends ALong {
  constructor() {
    const oLong = {
      __proto__: {
        m() {
          return 'P';
        },
      },
      n() {
        return super.m();
      },
    };
    super();
    this.r = oLong.n();
  }
}
console.log(new BLong().r);
