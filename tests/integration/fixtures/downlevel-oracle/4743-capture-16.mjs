const fLong = [];
for (var iLong = 0; iLong < 2; iLong++) {
  const vLong = iLong;
  fLong.push(
    function () {
      return this.k + vLong;
    }.bind({ k: 'k' }),
  );
}
console.log(fLong.map((gLong) => gLong()).join());
