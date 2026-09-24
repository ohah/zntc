function* g() {
  for (const k in { a: 1 }) {
    let k = 'x';
    yield k;
  }
}
console.log([...g()].join());
