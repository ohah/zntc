function* g() {
  for (const [c, d = '-'] in { ab: 1, c: 2 }) yield c + d;
}
console.log([...g()].join());
