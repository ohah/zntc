function* g() {
  for (var k in { a: 1, b: 2 }) yield k;
  yield 'last:' + k;
}
console.log([...g()].join());
