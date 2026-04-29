function* gen() {
  yield 1;
  yield 2;
  return "done";
}
const g = gen();
console.log(g.next(), g.next(), g.next(), g.next());
