const fLong = [];
let iLong = 0;
while (iLong < 2) {
  const vLong = iLong++;
  fLong.push(() => vLong);
}
console.log(fLong.map((gLong) => gLong()).join());
