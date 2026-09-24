const fLong = [];
for (var iLong = 0; iLong < 2; iLong++) {
  let vLong = iLong;
  fLong.push(() => vLong);
  vLong += 100;
}
console.log(fLong.map((gLong) => gLong()).join());
