class A {
  get k() {
    return 'kk';
  }
}
class B extends A {
  m() {
    const o = {
      __proto__: {
        kk() {
          return 'P';
        },
      },
      [super.k]() {
        return super.kk();
      },
    };
    return o.kk();
  }
}
console.log(new B().m());
