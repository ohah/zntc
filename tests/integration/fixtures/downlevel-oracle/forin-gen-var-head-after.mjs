function* gLong() {
  for (var kLong in { a: 1, b: 2 }) yield kLong;
  yield 'last:' + kLong;
}
console.log([...gLong()].join());
