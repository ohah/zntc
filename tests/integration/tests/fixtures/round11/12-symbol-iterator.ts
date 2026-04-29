class Range {
  constructor(public start: number, public end: number) {}
  *[Symbol.iterator]() {
    for (let i = this.start; i <= this.end; i++) yield i;
  }
}
const r = new Range(1, 5);
console.log([...r], Array.from(r));
