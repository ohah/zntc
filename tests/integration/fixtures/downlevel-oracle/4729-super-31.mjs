const out = [];
const ps = [
  {
    m() {
      return 0;
    },
  },
  {
    m() {
      return 1;
    },
  },
];
for (var iLong = 0; iLong < 2; iLong++) {
  out.push({
    __proto__: ps[iLong],
    async n() {
      return super.m();
    },
  });
}
Promise.all(out.map((oLong) => oLong.n())).then((vLong) => console.log(vLong.join()));
