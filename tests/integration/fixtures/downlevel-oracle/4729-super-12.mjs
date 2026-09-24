const oLong = {
  __proto__: {
    m() {
      return 'o';
    },
  },
  n() {
    return (
      {
        __proto__: {
          m() {
            return 'i';
          },
        },
        k() {
          return super.m();
        },
      }.k() + super.m()
    );
  },
};
console.log(oLong.n());
