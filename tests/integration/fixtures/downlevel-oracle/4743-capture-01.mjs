const fLong = [];
for (let iLong = 0; iLong < 2; iLong++) {
  const vLong = iLong * 10;
  fLong.push(() => vLong);
}
console.log(fLong.map((gLong) => gLong()).join());
