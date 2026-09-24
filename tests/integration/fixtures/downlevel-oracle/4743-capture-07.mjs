const fLong = [];
for (var iLong = 0; iLong < 3; iLong++) {
  if (iLong === 1) continue;
  const vLong = iLong;
  fLong.push(() => vLong);
  if (iLong === 2) break;
}
console.log(fLong.map((gLong) => gLong()).join());
