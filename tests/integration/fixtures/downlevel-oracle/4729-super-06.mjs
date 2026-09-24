class A {
  x() {
    return 'A';
  }
}
class B extends A {
  m() {
    const o = {
      __proto__: {
        x() {
          return 'P';
        },
      },
      n() {
        return super.x();
      },
    };
    return o.n() + super.x();
  }
}
console.log(new B().m());
