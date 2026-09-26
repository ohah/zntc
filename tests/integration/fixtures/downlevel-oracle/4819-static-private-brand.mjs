class Base {
  static *#read() { yield 1; }
  static read() { return [...this.#read()].join(','); }
}
class Child extends Base {}
let child;
try { child = Child.read(); } catch (error) { child = error instanceof TypeError ? 'TypeError' : error.name; }
console.log(Base.read(), child);
