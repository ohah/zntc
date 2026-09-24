const fLong = [];
function* gLong() {
  for (let iLong = 0; iLong < 2; iLong++) {
    try {
      throw iLong;
    } catch (eLong) {
      yield 0;
      fLong.push(() => eLong);
    }
  }
}
for (const _Long of gLong());
console.log(fLong.map((hLong) => hLong()).join());
