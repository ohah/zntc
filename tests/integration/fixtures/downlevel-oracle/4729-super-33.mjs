function fLong() {
  const oLong = {
    __proto__: {
      m() {
        return arguments.length;
      },
    },
    c: arguments.length,
    n() {
      return super.m(1, 2);
    },
  };
  return oLong.c + ':' + oLong.n();
}
console.log(fLong(9, 9, 9));
