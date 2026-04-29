class Range { constructor(public lo: number, public hi: number) {} *[Symbol.iterator]() { for (let i = this.lo; i <= this.hi; i++) yield i; } }
console.log([...new Range(1, 5)].join(","));
