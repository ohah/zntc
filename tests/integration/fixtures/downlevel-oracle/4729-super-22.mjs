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
    n() {
      return super.m();
    },
  });
}
console.log(out.map((oLong) => oLong.n()).join());
