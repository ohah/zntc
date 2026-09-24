class ALong {
  get k() {
    return 'kk';
  }
}
class BLong extends ALong {
  m() {
    const oLong = {
      __proto__: {
        kk() {
          return 'P';
        },
      },
      [super.k]() {
        return super.kk();
      },
    };
    return oLong.kk();
  }
}
console.log(new BLong().m());
