async function fLong() {
  for (let iLong = 0; iLong < 2; iLong++) {
    await 0;
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
    setTimeout(() => console.log(oLong.n()));
  }
}
fLong();
