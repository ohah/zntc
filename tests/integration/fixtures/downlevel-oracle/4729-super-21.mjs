class A {
  static s() {
    return 'S';
  }
}
class B extends A {
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
console.log(B.f, B.g());
