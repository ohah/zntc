const fLong = [];
async function gLong() {
  let iLong = 0;
  while (iLong < 2) {
    const vLong = iLong++;
    await 0;
    fLong.push(() => vLong);
  }
}
gLong().then(() => console.log(fLong.map((hLong) => hLong()).join()));
