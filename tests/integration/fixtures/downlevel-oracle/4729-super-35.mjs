const out = [];
for (var i = 0; i < 2; i++) {
  out.push({
    __proto__: {
      m() {
        return 10;
      },
    },
    async n() {
      await 0;
      return [0].map(() => super.m())[0];
    },
  });
}
Promise.all(out.map((o) => o.n())).then((v) => console.log(v.join()));
