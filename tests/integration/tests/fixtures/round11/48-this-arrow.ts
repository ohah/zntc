class Counter {
  count = 0;
  bump = () => { this.count++; return this.count; };
  bumpFn() {
    return [1, 2, 3].map(() => ++this.count);
  }
}
const c = new Counter();
console.log(c.bump(), c.bump());
const detached = c.bump;
console.log(detached());
const c2 = new Counter();
console.log(c2.bumpFn(), c2.count);
