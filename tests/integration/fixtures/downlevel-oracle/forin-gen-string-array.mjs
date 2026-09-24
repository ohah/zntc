function* g() {
  for (const i in 'ab') yield i;
  for (const i in [5, 6]) yield i;
}
console.log([...g()].join());
