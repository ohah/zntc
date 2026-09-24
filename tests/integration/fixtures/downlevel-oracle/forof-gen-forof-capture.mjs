const fLong = [];
function* gLong() {
  for (const xLong of [1, 2]) {
    yield xLong;
    fLong.push(() => xLong);
  }
}
for (const _Long of gLong());
console.log(fLong.map((hLong) => hLong()).join());
