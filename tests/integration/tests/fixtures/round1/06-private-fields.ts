class C {
  #x = 1;
  static #y = 2;
  get(){ return C.#y + this.#x; }
  static stat(){ return C.#y; }
}
const c = new C();
console.log(c.get(), C.stat());
