const out = [];
for (var iLong = 0; iLong < 2; iLong++) {
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
Promise.all(out.map((oLong) => oLong.n())).then((vLong) => console.log(vLong.join()));
