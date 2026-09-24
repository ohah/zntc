const out = [];
for (let iLong = 0; iLong < 2; iLong++) {
  const oLong = {
    __proto__: {
      m() {
        return iLong;
      },
    },
    n() {
      return super.m();
    },
  };
  out.push(oLong);
}
console.log(out.map((oLong2) => oLong2.n()).join());
