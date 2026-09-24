const o = {
  __proto__: {
    m() {
      return 'p';
    },
  },
  n() {
    const inner = {
      __proto__: {
        m() {
          return 'i';
        },
      },
      k() {
        return 'x';
      },
    };
    return inner.k() + super.m();
  },
};
console.log(o.n());
