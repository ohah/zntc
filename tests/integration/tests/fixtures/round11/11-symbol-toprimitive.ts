class Money {
  constructor(public amount: number) {}
  [Symbol.toPrimitive](hint: string) {
    if (hint === "number") return this.amount;
    if (hint === "string") return `$${this.amount}`;
    return `Money(${this.amount})`;
  }
}
const m = new Money(42);
console.log(+m, `${m}`, m + "");
