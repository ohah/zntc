const fLong = [];
let iLong = 0;
do {
  const vLong = iLong++;
  fLong.push(() => vLong);
} while (iLong < 2);
console.log(fLong.map((gLong) => gLong()).join());
