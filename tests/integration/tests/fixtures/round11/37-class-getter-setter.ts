class Temperature {
  #celsius = 0;
  get celsius() { return this.#celsius; }
  set celsius(v: number) { this.#celsius = v; }
  get fahrenheit() { return this.#celsius * 9 / 5 + 32; }
  set fahrenheit(v: number) { this.#celsius = (v - 32) * 5 / 9; }
}
const t = new Temperature();
t.celsius = 100;
console.log(t.celsius, t.fahrenheit);
t.fahrenheit = 32;
console.log(t.celsius);
