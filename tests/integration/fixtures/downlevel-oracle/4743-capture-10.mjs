const fLong = [];
for (var iLong = 0; iLong < 2; iLong++) {
  {
    const vLong = iLong;
    fLong.push(() => vLong);
  }
}
console.log(fLong.map((gLong) => gLong()).join());
