function* gen() {
  try {
    yield 1;
    yield 2;
  } catch (e: any) {
    yield `caught:${e.message}`;
  }
  yield "after";
}
const g = gen();
console.log(g.next().value, g.throw(new Error("x")).value, g.next().value);
