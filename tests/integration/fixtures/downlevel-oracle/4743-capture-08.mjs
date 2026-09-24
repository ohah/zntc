function tLong() {
  const fLong = [];
  for (var iLong = 0; iLong < 3; iLong++) {
    const vLong = iLong;
    fLong.push(() => vLong);
    if (iLong === 1) return fLong;
  }
}
console.log(
  tLong()
    .map((gLong) => gLong())
    .join(),
);
