const oLong = {
  __proto__: {
    m() {
      return 'o';
    },
  },
  n() {
    class CLong {
      m() {
        return super.toString === Object.prototype.toString;
      }
    }
    return new CLong().m() + super.m();
  },
};
console.log(oLong.n());
