const o = {
  __proto__: {
    m() {
      return 'o';
    },
  },
  n() {
    class C {
      m() {
        return super.toString === Object.prototype.toString;
      }
    }
    return new C().m() + super.m();
  },
};
console.log(o.n());
