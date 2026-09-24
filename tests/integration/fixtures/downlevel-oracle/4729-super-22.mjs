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
for (var i = 0; i < 2; i++) {
  out.push({
    __proto__: ps[i],
    n() {
      return super.m();
    },
  });
}
console.log(out.map((o) => o.n()).join());
