class Base {
  constructor(public x: number) {}
  greet() { return `base:${this.x}`; }
}
class Derived extends Base {
  constructor(x: number, public y: number) {
    super(x);
  }
  greet() { return `${super.greet()}/derived:${this.y}`; }
}
const d = new Derived(1, 2);
console.log(d.greet(), d.x, d.y);
