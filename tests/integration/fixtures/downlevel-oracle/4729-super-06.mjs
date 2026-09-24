class ALong {
  x() {
    return 'A';
  }
}
class BLong extends ALong {
  m() {
    const oLong = {
      __proto__: {
        x() {
          return 'P';
        },
      },
      n() {
        return super.x();
      },
    };
    return oLong.n() + super.x();
  }
}
console.log(new BLong().m());
