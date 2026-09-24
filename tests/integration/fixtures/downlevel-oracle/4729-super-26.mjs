const oLong = {
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
console.log(oLong.n());
