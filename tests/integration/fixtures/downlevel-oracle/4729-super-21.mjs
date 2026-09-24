class ALong {
  static s() {
    return 'S';
  }
}
class BLong extends ALong {
  static f = {
    __proto__: {
      m() {
        return 'P';
      },
    },
    n() {
      return super.m();
    },
  }.n();
  static g() {
    return (
      {
        __proto__: {
          m() {
            return 'Q';
          },
        },
        n() {
          return super.m();
        },
      }.n() + super.s()
    );
  }
}
console.log(BLong.f, BLong.g());
