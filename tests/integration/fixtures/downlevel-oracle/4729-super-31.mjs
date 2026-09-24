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
    async n() {
      return super.m();
    },
  });
}
Promise.all(out.map((o) => o.n())).then((v) => console.log(v.join()));
