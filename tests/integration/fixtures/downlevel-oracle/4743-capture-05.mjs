const fLong = [];
for (const kLong in { a: 1, b: 2 }) {
  const vLong = kLong + '!';
  fLong.push(() => vLong);
}
console.log(fLong.map((gLong) => gLong()).join());
