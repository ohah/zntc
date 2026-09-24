const o = {
  __proto__: {
    m() {
      return 1;
    },
  },
  n() {
    return (
      (function () {
        return this === undefined || this === globalThis;
      })() + super.m()
    );
  },
};
console.log(o.n());
