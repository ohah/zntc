const pLong = {
  m() {
    return 1;
  },
};
const oLong = {
  __proto__: pLong,
  async n() {
    await 0;
    return [0].map(() => super.m())[0];
  },
};
oLong.n().then((vLong) => console.log(vLong));
