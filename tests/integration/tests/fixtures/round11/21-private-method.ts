class Counter {
  #count = 0;
  #step = 1;
  #increment() { this.#count += this.#step; }
  bump() { this.#increment(); return this.#count; }
  get value() { return this.#count; }
  static #create() { return new Counter(); }
  static make() { return Counter.#create(); }
}
const c = Counter.make();
c.bump(); c.bump(); c.bump();
console.log(c.value);
