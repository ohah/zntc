const fLong = [];
function* gLong() {
  for (var iLong = 0; iLong < 2; iLong++) {
    const vLong = iLong;
    yield 0;
    fLong.push(() => vLong);
  }
}
for (const _Long of gLong());
console.log(fLong.map((hLong) => hLong()).join());
