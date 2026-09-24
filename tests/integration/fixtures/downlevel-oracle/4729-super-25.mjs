const p = {
  m() {
    return 1;
  },
};
const o = {
  __proto__: p,
  async n() {
    await 0;
    return [0].map(() => super.m())[0];
  },
};
o.n().then((v) => console.log(v));
