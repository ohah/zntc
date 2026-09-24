const fLong = [];
outer: for (var iLong = 0; iLong < 2; iLong++) {
  for (var jLong = 0; jLong < 2; jLong++) {
    const vLong = iLong * 10 + jLong;
    fLong.push(() => vLong);
    if (jLong === 0) continue outer;
  }
}
console.log(fLong.map((gLong) => gLong()).join());
