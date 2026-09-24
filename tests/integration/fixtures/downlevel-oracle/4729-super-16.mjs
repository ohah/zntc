const out = [];
for (let i = 0; i < 2; i++) {
  const o = {
    __proto__: {
      m() {
        return i;
      },
    },
    n() {
      return super.m();
    },
  };
  out.push(o);
}
console.log(out.map((o) => o.n()).join());
