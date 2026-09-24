async function fLong() {
  const rLong = [];
  for (var iLong = 0; iLong < 2; iLong++) {
    rLong.push({
      __proto__: { v: iLong },
      w: await iLong,
      get g() {
        return super.v;
      },
    });
  }
  return rLong.map((oLong) => oLong.g);
}
fLong().then((vLong) => console.log(vLong.join()));
