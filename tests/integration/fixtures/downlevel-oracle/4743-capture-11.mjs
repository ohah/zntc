const fLong = [];
for (var iLong = 0; iLong < 2; iLong++) {
  class CLong {
    m() {
      return iLong;
    }
  }
  const cLong = CLong;
  fLong.push(() => cLong === CLong);
}
console.log(fLong.map((gLong) => gLong()).join());
