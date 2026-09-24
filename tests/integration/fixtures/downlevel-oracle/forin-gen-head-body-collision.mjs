function* gLong() {
  for (const kLong in { a: 1 }) {
    let kLong2 = 'x';
    yield kLong2;
  }
}
console.log([...gLong()].join());
