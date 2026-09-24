const fLong = [];
for (const xLong of [1, 2]) {
  const vLong = xLong * 2;
  fLong.push(() => vLong);
}
console.log(fLong.map((gLong) => gLong()).join());
