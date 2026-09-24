class A {
  m() {
    return 'A';
  }
}
class B extends A {
  constructor() {
    const o = {
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
    this.r = o.n();
  }
}
console.log(new B().r);
